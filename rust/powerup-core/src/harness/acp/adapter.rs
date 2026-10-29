//! The ACP adapter's rules: what `ACPAdapter` does with each call, each raw
//! stdout line of the agent, each exit and each timer, as effects the
//! platform carries out in order.
//!
//! The platform owns the process: it spawns it with its agent environment,
//! moves bytes through the pipes, and arms the timers. It calls in with what
//! happened and runs the returned effects in order before the next call; a
//! spawn runs at once, and its `spawned` or `spawn_failed` call (with their
//! effects) comes before the rest. The adapter never calls back. One adapter
//! lives as long as its `ACPAdapter`, across launches.

use std::collections::{HashMap, VecDeque};

use super::permission::{permission_choice, PermissionOption};
use super::rpc::{self, number, obj, string, ResponseId};
use super::update::{tool_detail, tool_name};
use crate::harness::{HarnessConfiguration, HarnessEvent, HarnessState};
use crate::json::{self, JsonValue};
use crate::text;
use crate::CoreError;

/// How long an agent gets to finish starting before it is stopped (HK-134):
/// a wedged agent must not leave the app "starting" forever.
pub const START_TIMEOUT_SECONDS: f64 = 30.0;

/// How long a stopped agent gets to exit after its stdin closes before it
/// is force-terminated (HK-154).
pub const KILL_GRACE_SECONDS: f64 = 2.0;

/// The ACP protocol version `initialize` declares (HK-132).
pub const PROTOCOL_VERSION: i64 = 1;

const NO_COMMAND: &str = "No ACP agent command is configured — check Settings → General → Harness.";
const NOT_RUNNING: &str = "Can't send that — the agent session isn't running.";
const START_TIMED_OUT: &str = "The ACP agent didn't finish starting within 30 seconds.";
const NO_SESSION_HINT: &str =
    "The ACP agent couldn't create a session. Is it logged in? (e.g. run `opencode auth login`)";

/// The adapter's published state: what `ACPAdapter` exposes to views and to
/// the session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpSnapshot {
    pub state: HarnessState,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    /// Summed per-turn usage (HK-141). ACP reports tokens, never dollars, so
    /// there is no cost field and every turn completes with no cost
    /// (HK-142).
    pub total_tokens: i64,
}

impl AcpSnapshot {
    fn stopped() -> Self {
        AcpSnapshot {
            state: HarnessState::Stopped,
            session_id: None,
            model_name: None,
            total_tokens: 0,
        }
    }
}

/// What the adapter asks the platform to do.
#[derive(Debug, Clone, PartialEq)]
pub enum AcpAdapterEffect {
    /// Assign the published state. It is pushed before any other effect
    /// whenever the state changed since the last one, and at the end of a
    /// call (HK-405), so whoever reads the state while carrying out an
    /// effect sees what `ACPAdapter` showed at that moment.
    Publish(AcpSnapshot),
    /// Spawn `executable` with `arguments` in `project_dir`, with the
    /// platform's agent environment and three pipes, then call
    /// [`AcpAdapter::spawned`] or [`AcpAdapter::spawn_failed`] with this
    /// generation before anything else.
    Spawn {
        generation: u64,
        executable: String,
        arguments: Vec<String>,
        project_dir: String,
    },
    /// Write one line, newline included, on the current agent's stdin.
    WriteStdin(Vec<u8>),
    /// Close the current agent's stdin.
    CloseStdin,
    /// Force-terminate the process that is current now if it still runs
    /// after `seconds` (HK-154). The platform captures the process when it
    /// runs this effect.
    TerminateAfterGrace { seconds: f64 },
    /// One-shot: after `seconds`, call [`AcpAdapter::start_watchdog_fired`]
    /// with this generation (HK-134). It is never cancelled; the adapter
    /// decides when it fires.
    ArmStartWatchdog { generation: u64, seconds: f64 },
    /// Hand an event to the session.
    Emit(HarnessEvent),
}

/// A request of ours waiting for its response, by JSON-RPC id.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Pending {
    Initialize,
    SessionNew,
    Prompt,
    /// The model asked for.
    SetModel(String),
    /// The mode asked for.
    SetMode(String),
}

/// An agent's permission request waiting for the user's answer.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PendingPermission {
    /// The request's JSON-RPC id as text: the id of the event the session
    /// answers by (HK-144).
    event_id: String,
    rpc_id: i64,
    options: Vec<PermissionOption>,
}

/// The ACP adapter's state between calls.
#[derive(Debug)]
pub struct AcpAdapter {
    state: HarnessState,
    session_id: Option<String>,
    model_name: Option<String>,
    total_tokens: i64,
    /// The snapshot last pushed as a `Publish` effect.
    published: AcpSnapshot,
    /// Bumped on every start, so output, exits and timers of a replaced
    /// launch are dropped instead of clobbering the newer one (HK-135).
    generation: u64,
    /// The generation of the process the platform holds, from its spawn to
    /// its exit. A stop keeps it: the process is still shutting down.
    process: Option<u64>,
    /// Lines are written only while the current agent's stdin is open.
    stdin_open: bool,
    /// The adapter asked the agent to stop, so its exit is expected
    /// (HK-136).
    stop_requested: bool,
    /// The start configuration's folder, sent as session/new's cwd.
    project_dir: String,
    /// The next JSON-RPC id. It counts from 1 per adapter and is never reset
    /// by a start (HK-401), as Swift's `nextRequestID` was not.
    next_request_id: i64,
    /// Our requests waiting for their responses (HK-146, HK-401).
    pending: HashMap<i64, Pending>,
    /// The agent's permission requests waiting for an answer, in arrival
    /// order (HK-407).
    permissions: Vec<PendingPermission>,
    /// Prompts accepted while the session starts or a turn is in flight,
    /// sent first in, first out, one at a time (HK-138).
    queued_prompts: VecDeque<String>,
    /// This turn's streamed reply text (HK-139).
    reply_buffer: String,
    /// The effects of the call in progress.
    effects: Vec<AcpAdapterEffect>,
}

impl Default for AcpAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl AcpAdapter {
    /// A stopped adapter at generation 0.
    pub fn new() -> Self {
        AcpAdapter {
            state: HarnessState::Stopped,
            session_id: None,
            model_name: None,
            total_tokens: 0,
            published: AcpSnapshot::stopped(),
            generation: 0,
            process: None,
            stdin_open: false,
            stop_requested: false,
            project_dir: String::new(),
            next_request_id: 1,
            pending: HashMap::new(),
            permissions: Vec::new(),
            queued_prompts: VecDeque::new(),
            reply_buffer: String::new(),
            effects: Vec::new(),
        }
    }

    pub fn snapshot(&self) -> AcpSnapshot {
        AcpSnapshot {
            state: self.state,
            session_id: self.session_id.clone(),
            model_name: self.model_name.clone(),
            total_tokens: self.total_tokens,
        }
    }

    /// The current launch generation; 0 before the first start.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    // MARK: calls

    /// Starts a launch: a running agent is stopped first, then a new
    /// generation begins with nothing left from the old one, and the agent
    /// command is spawned in the project folder. The JSON-RPC ids keep
    /// counting (HK-401).
    pub fn start(&mut self, configuration: &HarnessConfiguration) -> Vec<AcpAdapterEffect> {
        if self.process.is_some() {
            self.stop_inner();
        }
        self.generation = self.generation.wrapping_add(1);
        self.pending.clear();
        // Answered (cancelled) by the stop above when an agent was running.
        self.permissions.clear();
        self.queued_prompts.clear();
        self.reply_buffer.clear();
        self.stop_requested = false;
        self.session_id = None;
        self.model_name = None;
        self.total_tokens = 0;
        self.state = HarnessState::Starting;
        self.project_dir = configuration.project_dir.clone();
        match configuration.agent_command.as_deref() {
            Some([executable, arguments @ ..]) => {
                self.push(AcpAdapterEffect::Spawn {
                    generation: self.generation,
                    executable: executable.clone(),
                    arguments: arguments.to_vec(),
                    project_dir: self.project_dir.clone(),
                });
            }
            _ => {
                self.state = HarnessState::Stopped;
                self.emit(HarnessEvent::RuntimeError(NO_COMMAND.to_owned()));
            }
        }
        self.finish()
    }

    /// The agent of `generation` runs: the handshake begins with
    /// `initialize`, which declares protocol version 1 and no filesystem
    /// capability, so the agent never calls fs methods PowerUp would refuse
    /// (HK-132), and the start watchdog is armed (HK-134).
    pub fn spawned(&mut self, generation: u64) -> Vec<AcpAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        self.process = Some(generation);
        self.stdin_open = true;
        let capabilities = obj(vec![(
            "fs",
            obj(vec![
                ("readTextFile", JsonValue::Bool(false)),
                ("writeTextFile", JsonValue::Bool(false)),
            ]),
        )]);
        self.request(
            Pending::Initialize,
            "initialize",
            obj(vec![
                ("protocolVersion", number(PROTOCOL_VERSION)),
                ("clientCapabilities", capabilities),
            ]),
        );
        self.push(AcpAdapterEffect::ArmStartWatchdog {
            generation,
            seconds: START_TIMEOUT_SECONDS,
        });
        self.finish()
    }

    /// Spawning `executable` for `generation` failed with `description`.
    pub fn spawn_failed(
        &mut self,
        generation: u64,
        executable: &str,
        description: &str,
    ) -> Vec<AcpAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        self.state = HarnessState::Stopped;
        self.emit(HarnessEvent::RuntimeError(format!(
            "Couldn't start the ACP agent ({executable}): {description}"
        )));
        self.finish()
    }

    /// Sends a prompt (HK-138): trimmed, and nothing when empty. While the
    /// session starts or a turn runs it is queued and the state reads
    /// working at once; when stopped it is refused with a message, never
    /// dropped silently.
    pub fn send(&mut self, text: &str) -> Vec<AcpAdapterEffect> {
        let trimmed = text::trim(text);
        if trimmed.is_empty() {
            return self.finish();
        }
        match self.state {
            HarnessState::Stopped => self.emit(HarnessEvent::RuntimeError(NOT_RUNNING.to_owned())),
            HarnessState::Starting | HarnessState::Working => {
                self.queued_prompts.push_back(trimmed.to_owned());
                self.state = HarnessState::Working;
            }
            HarnessState::Ready => self.send_prompt(trimmed.to_owned()),
        }
        self.finish()
    }

    /// Interrupts the turn (HK-143): every pending permission request is
    /// answered cancelled first, so the agent never hangs on one, then
    /// `session/cancel` goes out and the interrupt is reported done at once,
    /// without waiting for the agent. With no session nothing happens. The
    /// state stays as it is; the prompt's own result ends the turn.
    pub fn interrupt(&mut self) -> Vec<AcpAdapterEffect> {
        if let Some(session_id) = self.session_id.clone() {
            self.cancel_permissions();
            self.write(rpc::notification_line(
                "session/cancel",
                obj(vec![("sessionId", string(&session_id))]),
            ));
            self.emit(HarnessEvent::ControlResult {
                action: "interrupt".to_owned(),
                ok: true,
                detail: String::new(),
                value: None,
            });
        }
        self.finish()
    }

    /// Answers the permission request whose event id is `id` (HK-131,
    /// HK-144): the option [`permission_choice`] picks, or cancelled when
    /// none matches. The request is answered once; a second answer, or an
    /// id nobody asked about, does nothing.
    pub fn respond_to_permission(&mut self, id: &str, allow: bool) -> Vec<AcpAdapterEffect> {
        if let Some(at) = self
            .permissions
            .iter()
            .position(|permission| permission.event_id == id)
        {
            let permission = self.permissions.remove(at);
            let outcome = match permission_choice(&permission.options, allow) {
                Some(option_id) => obj(vec![
                    ("outcome", string("selected")),
                    ("optionId", string(option_id)),
                ]),
                None => obj(vec![("outcome", string("cancelled"))]),
            };
            self.write(rpc::result_line(
                ResponseId::Ours(permission.rpc_id),
                obj(vec![("outcome", outcome)]),
            ));
        }
        self.finish()
    }

    /// Switches the model (HK-148): trimmed; with no model or no session
    /// nothing is sent, and nothing is queued either.
    pub fn set_model(&mut self, model: &str) -> Vec<AcpAdapterEffect> {
        let trimmed = text::trim(model);
        if let (false, Some(session_id)) = (trimmed.is_empty(), self.session_id.clone()) {
            self.request(
                Pending::SetModel(trimmed.to_owned()),
                "session/set_model",
                obj(vec![
                    ("sessionId", string(&session_id)),
                    ("modelId", string(trimmed)),
                ]),
            );
        }
        self.finish()
    }

    /// Switches the permission mode, as [`AcpAdapter::set_model`] does.
    pub fn set_permission_mode(&mut self, mode: &str) -> Vec<AcpAdapterEffect> {
        let trimmed = text::trim(mode);
        if let (false, Some(session_id)) = (trimmed.is_empty(), self.session_id.clone()) {
            self.request(
                Pending::SetMode(trimmed.to_owned()),
                "session/set_mode",
                obj(vec![
                    ("sessionId", string(&session_id)),
                    ("modeId", string(trimmed)),
                ]),
            );
        }
        self.finish()
    }

    /// Stops the session: pending permission requests are answered
    /// cancelled while stdin is still open (HK-143), then stdin closes, the
    /// state reads stopped with no session, and the process is
    /// force-terminated if it still runs after [`KILL_GRACE_SECONDS`]
    /// (HK-154). Its exit is then expected (HK-136), and its late lines are
    /// dropped (HK-135), so a dying agent's late permission request cannot
    /// bring back a prompt the user just stopped. A second stop before the
    /// exit only arms another kill. With no process only the state changes,
    /// and the session id stays, as it did in Swift.
    pub fn stop(&mut self) -> Vec<AcpAdapterEffect> {
        self.stop_inner();
        self.finish()
    }

    // MARK: what the agent did

    /// One raw stdout line of the agent of `generation`, newline removed.
    /// The platform feeds lines one per call, in order. A line of a replaced
    /// launch, or any line after a stop, is dropped (HK-135), checked per
    /// line (HK-408). A line that is not a JSON object is ignored (HK-146).
    pub fn stdout_line(&mut self, generation: u64, line: &[u8]) -> Vec<AcpAdapterEffect> {
        if generation != self.generation || self.state == HarnessState::Stopped {
            return Vec::new();
        }
        if let Some(message) = json::read(line).filter(|value| value.as_object().is_some()) {
            self.dispatch(&message);
        }
        self.finish()
    }

    /// The agent of `generation` exited with `exit_code`; `stderr_tail` is
    /// the end of what it wrote on stderr. An exit nobody asked for reports
    /// the tail and an ended event; an expected one is silent (HK-136).
    /// Pending permission requests are dropped without an answer, since
    /// stdin is gone with the process (HK-407). The exit of a replaced
    /// launch only releases its process.
    pub fn terminated(
        &mut self,
        generation: u64,
        exit_code: i32,
        stderr_tail: &str,
    ) -> Vec<AcpAdapterEffect> {
        if generation != self.generation {
            if self.process == Some(generation) {
                self.process = None;
                self.stdin_open = false;
            }
            return Vec::new();
        }
        let expected = self.stop_requested;
        self.process = None;
        self.stdin_open = false;
        self.pending.clear();
        // stdin is closed, so nothing is written.
        self.cancel_permissions();
        self.state = HarnessState::Stopped;
        self.session_id = None;
        if !expected {
            if !stderr_tail.is_empty() {
                self.emit(HarnessEvent::RuntimeError(stderr_tail.to_owned()));
            }
            self.emit(HarnessEvent::Ended { exit_code });
        }
        self.finish()
    }

    /// The start watchdog of `generation` fired (HK-134, HK-406). It stops
    /// the agent only if that same launch is still starting, so it never
    /// kills a healthy later launch. A prompt sent while starting already
    /// reads working, so that launch is never stopped by its watchdog
    /// (kept from Swift).
    pub fn start_watchdog_fired(&mut self, generation: u64) -> Vec<AcpAdapterEffect> {
        if generation == self.generation && self.state == HarnessState::Starting {
            self.emit(HarnessEvent::RuntimeError(START_TIMED_OUT.to_owned()));
            self.stop_inner();
        }
        self.finish()
    }

    // MARK: incoming messages

    /// Routes one message (HK-402): a response to one of our pending
    /// requests first, matched by Swift's `as? Int` on its id and removed on
    /// the first match, even when it also carries a method; then a message
    /// with a method and an `id` key (null included) is the agent's own
    /// request, never an update; then a `session/update` notification.
    /// Anything else is ignored.
    fn dispatch(&mut self, message: &JsonValue) {
        let id = message.get("id");
        if let Some(pending) = id
            .and_then(JsonValue::as_swift_int)
            .and_then(|id| self.pending.remove(&id))
        {
            self.response(pending, message);
            return;
        }
        let Some(method) = message.get("method").and_then(JsonValue::as_str) else {
            return;
        };
        match id {
            Some(id) => self.agent_request(method, id, message.get("params")),
            None if method == "session/update" => self.session_update(message.get("params")),
            None => {}
        }
    }

    /// A request from the agent. Only `session/request_permission` is
    /// served; any other method (fs/*, terminal/*, even session/update sent
    /// with an id) gets -32601, because silence would hang the agent
    /// (HK-145).
    fn agent_request(&mut self, method: &str, id: &JsonValue, params: Option<&JsonValue>) {
        if method != "session/request_permission" {
            self.write(rpc::error_line(
                ResponseId::Echo(id),
                rpc::METHOD_NOT_FOUND,
                &format!("PowerUp does not support {method}"),
            ));
            return;
        }
        // HK-144: the event id is the rpc id as text; an id Swift could not
        // read as an Int is answered cancelled at once, echoed as read.
        let Some(rpc_id) = id.as_swift_int() else {
            self.write(rpc::result_line(ResponseId::Echo(id), cancelled()));
            return;
        };
        let params = params.filter(|params| params.as_object().is_some());
        let tool_call = params
            .and_then(|params| params.get("toolCall"))
            .filter(|tool_call| tool_call.as_object().is_some());
        let field = |key: &str| tool_call.and_then(|tool_call| tool_call.get(key)?.as_str());
        let name = field("title").unwrap_or("run a tool").to_owned();
        let kind = field("kind").unwrap_or("").to_owned();
        let detail = tool_detail(tool_call);
        // HK-403: one option that is not an object empties the list.
        let options = params
            .and_then(|params| params.get("options"))
            .and_then(JsonValue::as_object_array)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|option| {
                Some(PermissionOption {
                    option_id: option.get("optionId")?.as_str()?.to_owned(),
                    kind: option
                        .get("kind")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_owned(),
                })
            })
            .collect();
        let event_id = rpc_id.to_string();
        let permission = PendingPermission {
            event_id: event_id.clone(),
            rpc_id,
            options,
        };
        // HK-407: a repeated id replaces the options where they were.
        match self
            .permissions
            .iter_mut()
            .find(|pending| pending.event_id == event_id)
        {
            Some(pending) => *pending = permission,
            None => self.permissions.push(permission),
        }
        self.emit(HarnessEvent::PermissionRequest {
            id: event_id,
            name,
            kind,
            detail,
        });
    }

    /// The response to one of our requests.
    fn response(&mut self, pending: Pending, message: &JsonValue) {
        let result = message
            .get("result")
            .filter(|value| value.as_object().is_some());
        let error = message
            .get("error")
            .filter(|value| value.as_object().is_some());
        let error_text = error
            .and_then(|error| error.get("message"))
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_owned();
        match pending {
            Pending::Initialize => {
                // HK-147: no half-open session.
                if error.is_some() {
                    self.emit(HarnessEvent::RuntimeError(format!(
                        "The ACP agent rejected initialize: {error_text}"
                    )));
                    self.stop_inner();
                    return;
                }
                // HK-132: session/new only now, with the project folder and
                // an empty mcpServers (omitting it breaks some agents).
                let project_dir = self.project_dir.clone();
                self.request(
                    Pending::SessionNew,
                    "session/new",
                    obj(vec![
                        ("cwd", string(&project_dir)),
                        ("mcpServers", JsonValue::Array(Vec::new())),
                    ]),
                );
            }
            Pending::SessionNew => {
                let session_id = result
                    .and_then(|result| result.get("sessionId"))
                    .and_then(JsonValue::as_str)
                    .filter(|_| error.is_none());
                let Some(session_id) = session_id.map(str::to_owned) else {
                    // HK-147: most often an agent that is not logged in.
                    let message = if error_text.is_empty() {
                        NO_SESSION_HINT.to_owned()
                    } else {
                        format!("The ACP agent couldn't create a session: {error_text}")
                    };
                    self.emit(HarnessEvent::RuntimeError(message));
                    self.stop_inner();
                    return;
                };
                self.session_id = Some(session_id.clone());
                self.model_name = result
                    .and_then(|result| result.get("models"))
                    .and_then(|models| models.get("currentModelId"))
                    .and_then(JsonValue::as_str)
                    .map(str::to_owned);
                // A prompt queued while starting already reads working.
                if self.state == HarnessState::Starting {
                    self.state = HarnessState::Ready;
                }
                let model = self.model_name.clone().unwrap_or_else(|| "acp".to_owned());
                self.emit(HarnessEvent::SessionReady { session_id, model });
                self.send_next_queued();
            }
            Pending::Prompt => {
                // HK-141, HK-403: NSNumber's intValue, summed only when
                // positive; saturating where Swift would trap.
                if let Some(usage) = result
                    .and_then(|result| result.get("usage"))
                    .filter(|usage| usage.as_object().is_some())
                {
                    let tokens = |key: &str| {
                        usage
                            .get(key)
                            .and_then(JsonValue::as_swift_int_value)
                            .unwrap_or(0)
                    };
                    let turn = tokens("inputTokens").saturating_add(tokens("outputTokens"));
                    if turn > 0 {
                        self.total_tokens = self.total_tokens.saturating_add(turn);
                    }
                }
                // HK-140: refusal is an error turn; a missing stopReason is
                // end_turn, or error when the response is an error.
                let stop_reason = result
                    .and_then(|result| result.get("stopReason"))
                    .and_then(JsonValue::as_str)
                    .unwrap_or(if error.is_some() { "error" } else { "end_turn" })
                    .to_owned();
                // HK-139: the whole reply once, after its deltas.
                let reply = text::trim(&self.reply_buffer).to_owned();
                self.reply_buffer.clear();
                if !reply.is_empty() {
                    self.emit(HarnessEvent::Reply(reply.clone()));
                }
                let is_error = error.is_some() || stop_reason == "refusal";
                let detail = match (error.is_some(), error_text.is_empty()) {
                    (true, true) => "error".to_owned(),
                    (true, false) => error_text,
                    (false, _) => stop_reason,
                };
                self.emit(HarnessEvent::TurnCompleted {
                    result_text: (!reply.is_empty()).then_some(reply),
                    cost_usd: None,
                    is_error,
                    detail,
                });
                self.state = HarnessState::Ready;
                self.send_next_queued();
            }
            Pending::SetModel(model) => {
                // HK-148: only an accepted switch changes the model.
                let ok = error.is_none();
                if ok {
                    self.model_name = Some(model.clone());
                }
                self.emit(control_result(
                    "set_model",
                    ok,
                    &error_text,
                    "the agent rejected the model",
                    model,
                ));
            }
            Pending::SetMode(mode) => {
                let ok = error.is_none();
                self.emit(control_result(
                    "set_permission_mode",
                    ok,
                    &error_text,
                    "the agent rejected the mode",
                    mode,
                ));
            }
        }
    }

    /// A `session/update` notification (HK-151). Its `sessionId` is never
    /// compared. Only reply chunks and tool calls show; every other kind,
    /// `agent_thought_chunk` above all, is ignored, so thoughts never reach
    /// the reply.
    fn session_update(&mut self, params: Option<&JsonValue>) {
        let Some(update) = params
            .and_then(|params| params.get("update"))
            .filter(|update| update.as_object().is_some())
        else {
            return;
        };
        match update.get("sessionUpdate").and_then(JsonValue::as_str) {
            Some("agent_message_chunk") => {
                let chunk = update
                    .get("content")
                    .and_then(|content| content.get("text"))
                    .and_then(JsonValue::as_str)
                    .filter(|text| !text.is_empty());
                if let Some(chunk) = chunk.map(str::to_owned) {
                    self.reply_buffer.push_str(&chunk);
                    self.emit(HarnessEvent::ReplyDelta(chunk));
                }
            }
            Some("tool_call") => {
                let name = tool_name(update);
                let detail = tool_detail(Some(update));
                self.emit(HarnessEvent::ToolUse { name, detail });
            }
            _ => {}
        }
    }

    // MARK: helpers

    /// Sends one prompt; without a session it goes back in the queue
    /// instead of being dropped (HK-138).
    fn send_prompt(&mut self, text: String) {
        let Some(session_id) = self.session_id.clone() else {
            self.queued_prompts.push_back(text);
            return;
        };
        self.reply_buffer.clear();
        self.state = HarnessState::Working;
        let prompt = JsonValue::Array(vec![obj(vec![
            ("type", string("text")),
            ("text", string(&text)),
        ])]);
        self.request(
            Pending::Prompt,
            "session/prompt",
            obj(vec![("sessionId", string(&session_id)), ("prompt", prompt)]),
        );
    }

    fn send_next_queued(&mut self) {
        if let Some(next) = self.queued_prompts.pop_front() {
            self.send_prompt(next);
        }
    }

    fn stop_inner(&mut self) {
        self.stop_requested = true;
        self.cancel_permissions();
        self.pending.clear();
        self.queued_prompts.clear();
        if self.process.is_none() {
            self.state = HarnessState::Stopped;
            return;
        }
        if self.stdin_open {
            self.stdin_open = false;
            self.push(AcpAdapterEffect::CloseStdin);
        }
        self.state = HarnessState::Stopped;
        self.session_id = None;
        self.push(AcpAdapterEffect::TerminateAfterGrace {
            seconds: KILL_GRACE_SECONDS,
        });
    }

    /// Answers every pending permission request cancelled, in arrival order
    /// (HK-143, HK-407), and forgets them. The answers are written only
    /// while stdin is open, as Swift's write was, so after an exit they are
    /// dropped silently.
    fn cancel_permissions(&mut self) {
        for permission in std::mem::take(&mut self.permissions) {
            self.write(rpc::result_line(
                ResponseId::Ours(permission.rpc_id),
                cancelled(),
            ));
        }
    }

    /// Records a request and writes it (HK-404): the id is consumed and the
    /// request recorded even when its line cannot be written, as Swift's
    /// `sendRequest` did.
    fn request(&mut self, pending: Pending, method: &str, params: JsonValue) {
        let id = self.next_request_id;
        self.next_request_id = self.next_request_id.wrapping_add(1);
        self.pending.insert(id, pending);
        self.write(rpc::request_line(id, method, params));
    }

    /// A line is written only while the agent's stdin is open; one that
    /// cannot be encoded is dropped, as JSONSerialization returning nil was.
    fn write(&mut self, line: Result<Vec<u8>, CoreError>) {
        if let (Ok(line), true) = (line, self.stdin_open) {
            self.push(AcpAdapterEffect::WriteStdin(line));
        }
    }

    fn emit(&mut self, event: HarnessEvent) {
        self.push(AcpAdapterEffect::Emit(event));
    }

    /// Pushes an effect, publishing a changed state first (HK-405).
    fn push(&mut self, effect: AcpAdapterEffect) {
        self.sync();
        self.effects.push(effect);
    }

    /// Publishes the state when it changed since the last publish.
    fn sync(&mut self) {
        let snapshot = self.snapshot();
        if snapshot != self.published {
            self.published = snapshot.clone();
            self.effects.push(AcpAdapterEffect::Publish(snapshot));
        }
    }

    /// Ends a call: a state changed since the last effect is published, and
    /// the call's effects are handed over.
    fn finish(&mut self) -> Vec<AcpAdapterEffect> {
        self.sync();
        std::mem::take(&mut self.effects)
    }
}

/// The answer to a permission request nobody picked an option for.
fn cancelled() -> JsonValue {
    obj(vec![(
        "outcome",
        obj(vec![("outcome", string("cancelled"))]),
    )])
}

/// A set_model or set_mode answer: the value asked for is echoed, and a
/// rejection without a message gets `fallback`.
fn control_result(
    action: &str,
    ok: bool,
    error_text: &str,
    fallback: &str,
    value: String,
) -> HarnessEvent {
    let detail = match (ok, error_text.is_empty()) {
        (true, _) => String::new(),
        (false, true) => fallback.to_owned(),
        (false, false) => error_text.to_owned(),
    };
    HarnessEvent::ControlResult {
        action: action.to_owned(),
        ok,
        detail,
        value: Some(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn configuration(command: Option<&[&str]>) -> HarnessConfiguration {
        HarnessConfiguration {
            project_dir: "/work/app".to_owned(),
            model: "default".to_owned(),
            permission_mode: "default".to_owned(),
            effort: "default".to_owned(),
            resume_session_id: None,
            binary_path_override: None,
            agent_command: command.map(|parts| parts.iter().map(|p| (*p).to_owned()).collect()),
        }
    }

    fn written(effects: &[AcpAdapterEffect]) -> Vec<serde_json::Value> {
        effects
            .iter()
            .filter_map(|effect| match effect {
                AcpAdapterEffect::WriteStdin(line) => Some(serde_json::from_slice(line).unwrap()),
                _ => None,
            })
            .collect()
    }

    fn emitted(effects: Vec<AcpAdapterEffect>) -> Vec<HarnessEvent> {
        effects
            .into_iter()
            .filter_map(|effect| match effect {
                AcpAdapterEffect::Emit(event) => Some(event),
                _ => None,
            })
            .collect()
    }

    /// A started, spawned adapter whose session `s1` is ready.
    fn ready() -> AcpAdapter {
        let mut adapter = AcpAdapter::new();
        adapter.start(&configuration(Some(&["agent"])));
        adapter.spawned(adapter.generation());
        let g = adapter.generation();
        adapter.stdout_line(g, br#"{"jsonrpc":"2.0","id":1,"result":{}}"#);
        adapter.stdout_line(
            g,
            br#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#,
        );
        assert_eq!(adapter.snapshot().state, HarnessState::Ready);
        adapter
    }

    #[test]
    fn responses_match_by_id_not_order() {
        let mut adapter = ready();
        let g = adapter.generation();
        let model = adapter.set_model("m2");
        let mode = adapter.set_permission_mode("plan");
        assert_eq!(written(&model)[0]["id"], 3);
        assert_eq!(written(&mode)[0]["id"], 4);
        let answer_mode =
            adapter.stdout_line(g, br#"{"jsonrpc":"2.0","id":4,"error":{"message":"no"}}"#);
        let answer_model = adapter.stdout_line(g, br#"{"jsonrpc":"2.0","id":3,"result":{}}"#);
        assert_eq!(
            emitted(answer_mode),
            [control_result(
                "set_permission_mode",
                false,
                "no",
                "",
                "plan".to_owned()
            )]
        );
        assert_eq!(
            emitted(answer_model),
            [control_result("set_model", true, "", "", "m2".to_owned())]
        );
        // Each request is answered once.
        assert!(adapter
            .stdout_line(g, br#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
            .is_empty());
    }

    #[test]
    fn request_ids_keep_counting_across_launches() {
        let mut adapter = ready();
        adapter.stop();
        let restart = adapter.start(&configuration(Some(&["agent"])));
        assert!(written(&restart).is_empty());
        let spawned = adapter.spawned(adapter.generation());
        assert_eq!(written(&spawned)[0]["method"], "initialize");
        assert_eq!(written(&spawned)[0]["id"], 3);
    }

    #[test]
    fn the_generation_wraps_instead_of_overflowing() {
        let mut adapter = AcpAdapter::new();
        adapter.generation = u64::MAX;
        let effects = adapter.start(&configuration(Some(&["agent"])));
        assert_eq!(adapter.generation(), 0);
        assert!(matches!(
            effects.last(),
            Some(AcpAdapterEffect::Spawn { generation: 0, .. })
        ));
    }

    #[test]
    fn token_totals_saturate() {
        let mut adapter = ready();
        let g = adapter.generation();
        adapter.send("one");
        adapter.stdout_line(
            g,
            br#"{"jsonrpc":"2.0","id":3,"result":{"usage":{"inputTokens":1e300,"outputTokens":1e300}}}"#,
        );
        assert_eq!(adapter.snapshot().total_tokens, i64::MAX);
        adapter.send("two");
        adapter.stdout_line(
            g,
            br#"{"jsonrpc":"2.0","id":4,"result":{"usage":{"inputTokens":9223372036854775807}}}"#,
        );
        assert_eq!(adapter.snapshot().total_tokens, i64::MAX);
    }

    #[test]
    fn a_nested_spawn_failure_is_not_overwritten_by_a_stale_publish() {
        let mut adapter = AcpAdapter::new();
        let start = adapter.start(&configuration(Some(&["agent", "acp"])));
        let starting = AcpSnapshot {
            state: HarnessState::Starting,
            ..AcpSnapshot::stopped()
        };
        assert_eq!(
            start,
            [
                AcpAdapterEffect::Publish(starting),
                AcpAdapterEffect::Spawn {
                    generation: 1,
                    executable: "agent".to_owned(),
                    arguments: vec!["acp".to_owned()],
                    project_dir: "/work/app".to_owned(),
                },
            ]
        );
        let failed = adapter.spawn_failed(1, "agent", "no such file");
        assert_eq!(
            failed,
            [
                AcpAdapterEffect::Publish(AcpSnapshot::stopped()),
                AcpAdapterEffect::Emit(HarnessEvent::RuntimeError(
                    "Couldn't start the ACP agent (agent): no such file".to_owned()
                )),
            ]
        );
    }
}
