//! The Claude adapter's process rules: what `ClaudeService` does with each
//! call, each stdout event and each exit, as effects the platform carries
//! out in order.
//!
//! The platform owns the process: it resolves the binary, spawns it, moves
//! bytes through the pipes and arms the kill timer. It calls in with what
//! happened (a call from the session, a parsed stdout event, an exit) and
//! runs the returned effects in order before the next call. The adapter
//! never calls back. One adapter lives as long as its `ClaudeService`,
//! across launches; the launch generation inside it is what lets late
//! output of a replaced process be told apart from the current one.

use std::collections::HashMap;

use super::event::ClaudeEvent;
use super::launch::launch_arguments;
use super::stdin::{control_request_line, user_turn_line, ControlRequest};
use crate::harness::{HarnessConfiguration, HarnessEvent, HarnessState};

/// How long a stopped process gets to finish after its stdin closes before
/// it is force-terminated (HK-078).
pub const KILL_GRACE_SECONDS: f64 = 2.0;

const BINARY_NOT_FOUND: &str = "claude CLI not found — set the path in Settings";
const NOT_RUNNING: &str = "Can't send that — the Claude session isn't running.";

/// The adapter's published state: what `ClaudeService` exposes to views and
/// to the session.
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeSnapshot {
    pub state: HarnessState,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    /// The session's total cost so far; it belongs to the app run, so a new
    /// launch keeps it.
    pub total_cost_usd: f64,
}

/// What the adapter asks the platform to do.
#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeAdapterEffect {
    /// Assign the published state. Emitted at every point `ClaudeService`
    /// assigned it, before any event that follows, so whoever reads the
    /// state while handling that event sees what it saw before.
    Publish(ClaudeSnapshot),
    /// Resolve the claude binary (the override, a login-shell lookup, the
    /// usual install spots) off the main thread, then call
    /// [`ClaudeAdapter::binary_resolved`] with this generation.
    ResolveBinary {
        generation: u64,
        binary_path_override: Option<String>,
    },
    /// Spawn `executable` with `arguments` in `project_dir`, with the
    /// platform's child environment and three pipes, then call
    /// [`ClaudeAdapter::spawned`] or [`ClaudeAdapter::spawn_failed`] with
    /// this generation before anything else.
    Spawn {
        generation: u64,
        executable: String,
        arguments: Vec<String>,
        project_dir: String,
    },
    /// Write one line, newline included, on the current process's stdin.
    /// A failed write is reported through
    /// [`ClaudeAdapter::stdin_write_failed`].
    WriteStdin(Vec<u8>),
    /// Close the current process's stdin, so the CLI can finish cleanly.
    CloseStdin,
    /// Force-terminate the process that is current now if it still runs
    /// after `seconds` (HK-078). The platform captures the process when it
    /// runs this effect: a start that follows replaces it.
    TerminateAfterGrace { seconds: f64 },
    /// Hand an event to the session.
    Emit(HarnessEvent),
}

/// The Claude adapter's state between calls.
#[derive(Debug)]
pub struct ClaudeAdapter {
    state: HarnessState,
    session_id: Option<String>,
    model_name: Option<String>,
    total_cost_usd: f64,
    /// Bumped on every start, so output and exits of a replaced process are
    /// dropped instead of clobbering the newer launch.
    generation: u64,
    /// The generation of the process the platform holds, from its spawn to
    /// its exit. A stop keeps it: the process is still shutting down.
    process: Option<u64>,
    stdin_open: bool,
    /// A system/init has been seen for the current launch.
    did_receive_init: bool,
    /// The last assistant message of this turn (HK-074).
    last_assistant_message: Option<String>,
    /// request id → the request, for every control request still waiting
    /// for its control_response (HK-070).
    in_flight: HashMap<String, ControlRequest>,
    /// Lines accepted while the binary resolves, written in order once the
    /// process is up (HK-079).
    pending_stdin: Vec<Vec<u8>>,
    project_dir: String,
    arguments: Vec<String>,
    request_prefix: String,
    requests_made: u64,
}

impl ClaudeAdapter {
    /// A stopped adapter. Request ids are `"<request_prefix>-<n>"` with `n`
    /// counting from 1 (HK-396): the CLI accepts any unique string (DESIGN.md
    /// v1.1 A), so the platform passes something unique per adapter, such as
    /// a UUID, and tests pass a fixed prefix.
    pub fn new(request_prefix: String) -> Self {
        ClaudeAdapter {
            state: HarnessState::Stopped,
            session_id: None,
            model_name: None,
            total_cost_usd: 0.0,
            generation: 0,
            process: None,
            stdin_open: false,
            did_receive_init: false,
            last_assistant_message: None,
            in_flight: HashMap::new(),
            pending_stdin: Vec::new(),
            project_dir: String::new(),
            arguments: Vec::new(),
            request_prefix,
            requests_made: 0,
        }
    }

    pub fn snapshot(&self) -> ClaudeSnapshot {
        ClaudeSnapshot {
            state: self.state,
            session_id: self.session_id.clone(),
            model_name: self.model_name.clone(),
            total_cost_usd: self.total_cost_usd,
        }
    }

    /// The current launch generation; 0 before the first start.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    fn publish(&self) -> ClaudeAdapterEffect {
        ClaudeAdapterEffect::Publish(self.snapshot())
    }

    fn runtime_error(message: String) -> ClaudeAdapterEffect {
        ClaudeAdapterEffect::Emit(HarnessEvent::RuntimeError(message))
    }

    /// A process is installed, still running, and its stdin is open.
    fn can_write(&self, process_running: bool) -> bool {
        self.process.is_some() && process_running && self.stdin_open
    }

    /// The binary is still resolving: what is sent now waits for the spawn.
    fn is_queueing(&self) -> bool {
        self.process.is_none()
            && matches!(self.state, HarnessState::Starting | HarnessState::Working)
    }

    /// Starts a launch: a running process is stopped first, then a new
    /// generation begins and the binary is resolved. A resumed launch owns
    /// its id at once, before system/init, so the hook echo guard and the
    /// protocol snapshot see it while the CLI starts (HK-075); the id is
    /// published as given, and only the argv trims it.
    pub fn start(&mut self, configuration: &HarnessConfiguration) -> Vec<ClaudeAdapterEffect> {
        let mut effects = if self.process.is_some() {
            self.stop()
        } else {
            Vec::new()
        };
        // Retire the old launch before anything can fail, and forget what
        // belonged to it, so an aborted launch leaves nothing stale.
        self.generation = self.generation.wrapping_add(1);
        self.did_receive_init = false;
        self.last_assistant_message = None;
        self.in_flight.clear();
        self.pending_stdin.clear();
        self.session_id = configuration.resume_session_id.clone();
        self.state = HarnessState::Starting;
        self.model_name = None;
        effects.push(self.publish());
        self.project_dir = configuration.project_dir.clone();
        self.arguments = launch_arguments(
            &configuration.model,
            &configuration.permission_mode,
            &configuration.effort,
            configuration.resume_session_id.as_deref(),
        );
        effects.push(ClaudeAdapterEffect::ResolveBinary {
            generation: self.generation,
            binary_path_override: configuration.binary_path_override.clone(),
        });
        effects
    }

    /// The binary of `generation` resolved (`None`: not found). A newer
    /// start, or a stop while resolving, abandons the launch.
    pub fn binary_resolved(
        &mut self,
        generation: u64,
        path: Option<String>,
    ) -> Vec<ClaudeAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        if self.state == HarnessState::Stopped {
            self.pending_stdin.clear();
            self.in_flight.clear();
            return Vec::new();
        }
        match path {
            None => {
                self.state = HarnessState::Stopped;
                self.session_id = None;
                self.pending_stdin.clear();
                self.in_flight.clear();
                vec![
                    self.publish(),
                    Self::runtime_error(BINARY_NOT_FOUND.to_owned()),
                ]
            }
            Some(executable) => vec![ClaudeAdapterEffect::Spawn {
                generation,
                executable,
                arguments: self.arguments.clone(),
                project_dir: self.project_dir.clone(),
            }],
        }
    }

    /// The process of `generation` runs: what was queued while the binary
    /// resolved is written now, in order (the CLI buffers stdin while it
    /// boots).
    pub fn spawned(&mut self, generation: u64) -> Vec<ClaudeAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        self.process = Some(generation);
        self.stdin_open = true;
        self.pending_stdin
            .drain(..)
            .map(ClaudeAdapterEffect::WriteStdin)
            .collect()
    }

    /// Spawning `executable` for `generation` failed with `description`.
    pub fn spawn_failed(
        &mut self,
        generation: u64,
        executable: &str,
        description: &str,
    ) -> Vec<ClaudeAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        self.state = HarnessState::Stopped;
        self.session_id = None;
        self.pending_stdin.clear();
        self.in_flight.clear();
        vec![
            self.publish(),
            Self::runtime_error(format!(
                "Couldn't start the claude CLI at {executable}: {description}"
            )),
        ]
    }

    /// Sends a user turn. `process_running` is the platform's answer for
    /// the current process. While the binary resolves the turn is queued;
    /// otherwise, without a running process, it is refused with a message
    /// and never silently dropped (HK-079).
    pub fn send(&mut self, text: &str, process_running: bool) -> Vec<ClaudeAdapterEffect> {
        // An encoding failure sends nothing, as Swift's encoder returning
        // nil did.
        let Ok(Some(line)) = user_turn_line(text) else {
            return Vec::new();
        };
        if self.is_queueing() {
            self.last_assistant_message = None;
            self.state = HarnessState::Working;
            self.pending_stdin.push(line);
            return vec![self.publish()];
        }
        if !self.can_write(process_running) {
            return vec![Self::runtime_error(NOT_RUNNING.to_owned())];
        }
        self.last_assistant_message = None;
        self.state = HarnessState::Working;
        vec![self.publish(), ClaudeAdapterEffect::WriteStdin(line)]
    }

    /// Interrupts the current turn.
    pub fn interrupt(&mut self, process_running: bool) -> Vec<ClaudeAdapterEffect> {
        self.control(Some(ControlRequest::Interrupt), process_running)
    }

    /// Switches the model live, without a restart; an empty model sends
    /// nothing (HK-068).
    pub fn set_model(&mut self, model: &str, process_running: bool) -> Vec<ClaudeAdapterEffect> {
        self.control(ControlRequest::set_model(model), process_running)
    }

    /// Switches the permission mode live; an empty mode sends nothing.
    pub fn set_permission_mode(
        &mut self,
        mode: &str,
        process_running: bool,
    ) -> Vec<ClaudeAdapterEffect> {
        self.control(ControlRequest::set_permission_mode(mode), process_running)
    }

    /// Writes one control request and records it as in flight. Queued like
    /// a turn while the binary resolves; without a running process it is
    /// dropped silently, since there is nothing to interrupt or switch.
    fn control(
        &mut self,
        request: Option<ControlRequest>,
        process_running: bool,
    ) -> Vec<ClaudeAdapterEffect> {
        let Some(request) = request else {
            return Vec::new();
        };
        self.requests_made = self.requests_made.wrapping_add(1);
        let request_id = format!("{}-{}", self.request_prefix, self.requests_made);
        let Ok(line) = control_request_line(&request_id, &request) else {
            return Vec::new();
        };
        if self.is_queueing() {
            self.in_flight.insert(request_id, request);
            self.pending_stdin.push(line);
            return Vec::new();
        }
        if !self.can_write(process_running) {
            return Vec::new();
        }
        self.in_flight.insert(request_id, request);
        vec![ClaudeAdapterEffect::WriteStdin(line)]
    }

    /// Stops the session: stdin closes first so the CLI can finish cleanly,
    /// then the process is force-terminated if it still runs after
    /// [`KILL_GRACE_SECONDS`] (HK-078). The process stays the adapter's
    /// until it exits. With no process (a launch still resolving), the
    /// launch is abandoned and nothing queued outlives it.
    pub fn stop(&mut self) -> Vec<ClaudeAdapterEffect> {
        if self.process.is_none() {
            self.pending_stdin.clear();
            self.in_flight.clear();
            if self.state == HarnessState::Stopped {
                return Vec::new();
            }
            self.state = HarnessState::Stopped;
            return vec![self.publish()];
        }
        let mut effects = Vec::new();
        if self.stdin_open {
            self.stdin_open = false;
            effects.push(ClaudeAdapterEffect::CloseStdin);
        }
        self.state = HarnessState::Stopped;
        effects.push(self.publish());
        effects.push(ClaudeAdapterEffect::TerminateAfterGrace {
            seconds: KILL_GRACE_SECONDS,
        });
        effects
    }

    /// One parsed stdout event of the process of `generation`. The platform
    /// feeds events one per call, in order, so the state each one leaves is
    /// published before the next; an event of a replaced process is
    /// dropped.
    pub fn stdout_event(
        &mut self,
        generation: u64,
        event: ClaudeEvent,
    ) -> Vec<ClaudeAdapterEffect> {
        if generation != self.generation {
            return Vec::new();
        }
        match event {
            ClaudeEvent::Ready { session_id, model } => {
                self.session_id = Some(session_id.clone());
                // Every init refreshes the model: after a live set_model the
                // CLI reports the new one here (HK-073).
                if !model.is_empty() {
                    self.model_name = Some(model.clone());
                }
                if !self.did_receive_init {
                    self.did_receive_init = true;
                    // A turn sent while the CLI booted is already in flight;
                    // don't downgrade it.
                    if self.state != HarnessState::Working {
                        self.state = HarnessState::Ready;
                    }
                } else if matches!(self.state, HarnessState::Stopped | HarnessState::Starting) {
                    self.state = HarnessState::Ready;
                }
                self.last_assistant_message = None;
                vec![
                    self.publish(),
                    ClaudeAdapterEffect::Emit(HarnessEvent::SessionReady { session_id, model }),
                ]
            }
            ClaudeEvent::AssistantMessage(text) => {
                // The CLI repeats the assistant message once per content
                // block (HK-074).
                if self.last_assistant_message.as_deref() == Some(text.as_str()) {
                    return Vec::new();
                }
                self.last_assistant_message = Some(text.clone());
                vec![ClaudeAdapterEffect::Emit(HarnessEvent::Reply(text))]
            }
            ClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            } => {
                // The total accumulates; a zero, negative or non-finite cost
                // never moves it (HK-066).
                if let Some(cost) = cost_usd {
                    if cost.is_finite() && cost > 0.0 {
                        self.total_cost_usd += cost;
                    }
                }
                self.last_assistant_message = None;
                self.state = HarnessState::Ready;
                vec![
                    self.publish(),
                    ClaudeAdapterEffect::Emit(HarnessEvent::TurnCompleted {
                        result_text,
                        cost_usd,
                        is_error,
                        detail: subtype,
                    }),
                ]
            }
            ClaudeEvent::ControlResult {
                action: request_id,
                ok,
                detail,
                value: _,
            } => {
                // Only a request this launch made and has not seen answered
                // is reported; a stale process's reply or one the CLI
                // invented is dropped (HK-070).
                let Some(request) = self.in_flight.remove(&request_id) else {
                    return Vec::new();
                };
                let mut effects = Vec::new();
                // Don't wait for the next init to show a live model switch;
                // the chip would lag a turn behind (HK-071).
                if let (true, ControlRequest::SetModel(model)) = (ok, &request) {
                    if !model.is_empty() {
                        self.model_name = Some(model.clone());
                        effects.push(self.publish());
                    }
                }
                effects.push(ClaudeAdapterEffect::Emit(HarnessEvent::ControlResult {
                    action: request.subtype().to_owned(),
                    ok,
                    detail,
                    value: request.value().map(str::to_owned),
                }));
                effects
            }
            other => vec![ClaudeAdapterEffect::Emit(HarnessEvent::from_claude(other))],
        }
    }

    /// The process of `generation` exited. `clean` is a normal exit with
    /// code 0; `stderr_tail` is the trimmed end of its stderr. The platform
    /// feeds the process's last stdout events first. A replaced process's
    /// exit only releases it. The current one's ends the session: an unclean
    /// exit explains itself, and the session id is cleared so the hook echo
    /// guard does not stay armed for an id nobody runs (HK-076).
    pub fn terminated(
        &mut self,
        generation: u64,
        exit_code: i32,
        clean: bool,
        stderr_tail: &str,
    ) -> Vec<ClaudeAdapterEffect> {
        if generation != self.generation {
            if self.process == Some(generation) {
                self.process = None;
                self.stdin_open = false;
            }
            return Vec::new();
        }
        let mut effects = Vec::new();
        if !clean {
            let message = if stderr_tail.is_empty() {
                format!("The claude process exited unexpectedly (code {exit_code}).")
            } else {
                stderr_tail.to_owned()
            };
            effects.push(Self::runtime_error(message));
        }
        self.process = None;
        self.stdin_open = false;
        self.in_flight.clear();
        self.state = HarnessState::Stopped;
        self.session_id = None;
        effects.push(self.publish());
        effects.push(ClaudeAdapterEffect::Emit(HarnessEvent::Ended { exit_code }));
        effects
    }

    /// A stdin write failed with `description`: the line never reached the
    /// CLI.
    pub fn stdin_write_failed(&mut self, description: &str) -> Vec<ClaudeAdapterEffect> {
        vec![Self::runtime_error(format!(
            "Couldn't reach the claude process: {description}"
        ))]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn configuration() -> HarnessConfiguration {
        HarnessConfiguration {
            project_dir: "/work/app".into(),
            model: "default".into(),
            permission_mode: "acceptEdits".into(),
            effort: "default".into(),
            resume_session_id: None,
            binary_path_override: None,
            agent_command: None,
        }
    }

    #[test]
    fn request_ids_carry_the_prefix_and_count_from_one() {
        let mut adapter = ClaudeAdapter::new("A1B2".into());
        adapter.start(&configuration());
        adapter.binary_resolved(1, Some("/bin/claude".into()));
        adapter.spawned(1);
        let lines: Vec<String> = [adapter.interrupt(true), adapter.set_model("opus", true)]
            .into_iter()
            .flatten()
            .filter_map(|effect| match effect {
                ClaudeAdapterEffect::WriteStdin(line) => String::from_utf8(line).ok(),
                _ => None,
            })
            .collect();
        assert_eq!(lines.len(), 2);
        assert!(
            lines[0].contains("\"request_id\":\"A1B2-1\""),
            "{}",
            lines[0]
        );
        assert!(
            lines[1].contains("\"request_id\":\"A1B2-2\""),
            "{}",
            lines[1]
        );
    }

    #[test]
    fn a_non_finite_cost_never_moves_the_total() {
        let mut adapter = ClaudeAdapter::new("R".into());
        for cost in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.25] {
            adapter.stdout_event(
                0,
                ClaudeEvent::TurnCompleted {
                    result_text: None,
                    cost_usd: Some(cost),
                    is_error: false,
                    subtype: "success".into(),
                },
            );
        }
        assert_eq!(adapter.snapshot().total_cost_usd, 0.25);
    }

    #[test]
    fn the_generation_wraps_instead_of_overflowing() {
        let mut adapter = ClaudeAdapter::new("R".into());
        adapter.generation = u64::MAX;
        adapter.start(&configuration());
        assert_eq!(adapter.generation(), 0);
    }
}
