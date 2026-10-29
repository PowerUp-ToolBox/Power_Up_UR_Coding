//! The session scenario runner (`Tests/Fixtures/session/`, format 1): the
//! Rust twin of `Tests/PowerUpTests/SessionScenario.swift`. It parses a
//! scenario as strictly as the Swift runner does, plays it on a
//! [`SessionMachine`] with two scripted harnesses, a recording injector and
//! a scripted clock, carries out the machine's effects the way the app
//! does, and compares the same observable facts with the same rules.
//!
//! The world it builds stands in for the app around the machine:
//! - the config, starting from the app's defaults with the scenario's
//!   `config` applied and the launch seeding AppState does;
//! - two scripted harnesses following the README's rules, one per kind;
//! - the transcript: the window's scrollback, each project folder's stored
//!   history, and the entries in order of first appearance;
//! - the injector's log, the published mirrors, the clock with its timers,
//!   and the deferred-task queue.
//!
//! Paths live in a virtual sandbox, `/sandbox`: `$name` is `/sandbox/name`.

// Test support, not library code: a broken scenario stops the test with
// the file and path named.
#![allow(clippy::expect_used)]

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use powerup_core::harness::{HarnessConfiguration, HarnessEvent, HarnessKind, HarnessState};
use powerup_core::intent::Intent;
use powerup_core::session::{
    ConfigChange, HarnessSnapshot, HookEvent, HookKind, PendingPermission, PlacedPath, RemoteKey,
    SessionContext, SessionEffect, SessionMachine, SessionSettings, TranscriptKind,
};
use powerup_core::status::{derived_is_working, derived_status, model_chip_label};
use serde_json::{Map, Value};

const SANDBOX: &str = "/sandbox";
/// The scripted clock's start, as in the Swift runner.
const CLOCK_START: f64 = 800_000_000.0;

// MARK: - Parsing

/// A load error: the file, the JSON path and what is wrong.
pub type LoadError = String;

#[derive(Debug, Default, Clone)]
struct Config {
    harness_kind: Option<String>,
    acp_agent: Option<String>,
    acp_custom_command: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    permission_mode: Option<String>,
    control_mode: Option<String>,
    project: bool,
    last_session_id: Option<String>,
    controller_connected: bool,
}

#[derive(Debug, Clone)]
enum CallStep {
    StartSessionIfNeeded,
    NewSession,
    SendUserText(String),
    InterruptClaude,
    AnswerPendingPermission(bool),
    SwitchProject(String),
}

#[derive(Debug, Clone, Default)]
struct SettingsChange {
    harness_kind: Option<String>,
    acp_agent: Option<String>,
    acp_custom_command: Option<String>,
}

#[derive(Debug, Clone)]
struct ScriptedHook {
    kind: HookKind,
    text: Option<String>,
    session_id: Option<String>,
    cwd: Option<String>,
}

#[derive(Debug, Clone)]
enum Action {
    Call(CallStep),
    Intent(Intent),
    Settings(SettingsChange),
    HarnessEvent(HarnessEvent, Option<HarnessKind>),
    HookEvent(ScriptedHook),
    AdvanceClock(f64),
}

#[derive(Debug, Clone)]
struct Step {
    number: usize,
    action: Action,
    expect_no_change: bool,
    settle: bool,
    expect: Option<Expectations>,
    label: String,
}

/// Facts checked after the script or at a step. `None` = not checked;
/// `Some(None)` asserts "no value".
#[derive(Debug, Clone, Default)]
struct Expectations {
    harness_calls: Option<Vec<Map<String, Value>>>,
    transcript: Option<Vec<Map<String, Value>>>,
    error_shown: Option<bool>,
    last_session_id: Option<Option<String>>,
    pending_permission: Option<bool>,
    pending_permission_armed: Option<bool>,
    status: Option<String>,
    live_model: Option<Option<String>>,
    model_chip: Option<String>,
    remote_turn_active: Option<bool>,
    remote_focus: Option<Option<String>>,
    injector_calls: Option<Vec<Map<String, Value>>>,
    permission_mode: Option<String>,
    live_session_id: Option<Option<String>>,
    last_assistant_reply: Option<Option<String>>,
}

/// One parsed scenario.
#[derive(Debug, Clone)]
pub struct Scenario {
    file: String,
    name: String,
    config: Config,
    script: Vec<Step>,
    expect: Expectations,
}

const STATUS_NAMES: [&str; 5] = ["noController", "idle", "listening", "thinking", "speaking"];
const TRANSCRIPT_KINDS: [&str; 5] = ["user", "assistant", "tool", "system", "error"];
const HARNESS_KINDS: [&str; 2] = ["claude", "acp"];

fn call_type_keys(kind: &str) -> Option<&'static [&'static str]> {
    Some(match kind {
        "start" => &[
            "projectDir",
            "model",
            "permissionMode",
            "effort",
            "resumeSessionID",
            "binaryPathOverride",
            "agentCommand",
        ],
        "send" => &["text"],
        "interrupt" | "stop" => &[],
        "setModel" => &["model"],
        "setPermissionMode" => &["mode"],
        "respondToPermission" => &["id", "allow"],
        _ => return None,
    })
}

fn injector_type_keys(kind: &str) -> Option<&'static [&'static str]> {
    Some(match kind {
        "text" => &["text", "submit"],
        "key" => &["key"],
        _ => return None,
    })
}

/// Typed, path-aware access to the parsed JSON, failing as the Swift
/// `Reader` does.
struct Reader<'a> {
    file: &'a str,
}

impl Reader<'_> {
    fn error(&self, path: &str, message: &str) -> LoadError {
        format!("{} {path}: {message}", self.file)
    }

    fn object<'v>(
        &self,
        json: Option<&'v Value>,
        path: &str,
        allowed: &[&str],
    ) -> Result<&'v Map<String, Value>, LoadError> {
        let Some(Value::Object(fields)) = json else {
            return Err(self.error(path, "must be an object"));
        };
        let mut keys: Vec<&String> = fields.keys().collect();
        keys.sort();
        if let Some(unknown) = keys.iter().find(|key| !allowed.contains(&key.as_str())) {
            let mut sorted = allowed.to_vec();
            sorted.sort_unstable();
            return Err(self.error(
                &format!("{path}.{unknown}"),
                &format!("unknown key (allowed: {})", sorted.join(", ")),
            ));
        }
        Ok(fields)
    }

    fn string(&self, json: Option<&Value>, path: &str) -> Result<String, LoadError> {
        match json {
            Some(Value::String(value)) => Ok(value.clone()),
            _ => Err(self.error(path, "must be a string")),
        }
    }

    fn optional_string(
        &self,
        json: Option<&Value>,
        path: &str,
    ) -> Result<Option<String>, LoadError> {
        match json {
            None | Some(Value::Null) => Ok(None),
            other => self.string(other, path).map(Some),
        }
    }

    fn harness_kind(&self, json: Option<&Value>, path: &str) -> Result<Option<String>, LoadError> {
        let Some(kind) = self.optional_string(json, path)? else {
            return Ok(None);
        };
        if !HARNESS_KINDS.contains(&kind.as_str()) {
            return Err(self.error(
                path,
                &format!(
                    "unknown harness kind \"{kind}\" (allowed: {})",
                    HARNESS_KINDS.join(", ")
                ),
            ));
        }
        Ok(Some(kind))
    }

    fn string_array(&self, json: Option<&Value>, path: &str) -> Result<Vec<String>, LoadError> {
        let Some(Value::Array(items)) = json else {
            return Err(self.error(path, "must be an array of strings"));
        };
        items
            .iter()
            .enumerate()
            .map(|(index, item)| self.string(Some(item), &format!("{path}[{index}]")))
            .collect()
    }

    fn bool(&self, json: Option<&Value>, path: &str) -> Result<bool, LoadError> {
        match json {
            Some(Value::Bool(value)) => Ok(*value),
            _ => Err(self.error(path, "must be true or false")),
        }
    }

    fn optional_bool(&self, json: Option<&Value>, path: &str) -> Result<Option<bool>, LoadError> {
        match json {
            None => Ok(None),
            other => self.bool(other, path).map(Some),
        }
    }

    fn int(&self, json: Option<&Value>, path: &str) -> Result<i32, LoadError> {
        match json.and_then(Value::as_f64) {
            Some(value) if value.round() == value && value.abs() <= f64::from(i32::MAX) =>
            {
                #[allow(clippy::cast_possible_truncation)]
                Ok(value as i32)
            }
            _ => Err(self.error(path, "must be an integer")),
        }
    }

    fn seconds(&self, json: Option<&Value>, path: &str) -> Result<f64, LoadError> {
        match json.and_then(Value::as_f64) {
            Some(value) if value.is_finite() && value >= 0.0 => Ok(value),
            _ => Err(self.error(path, "must be a number of seconds, zero or more")),
        }
    }

    fn optional_double(&self, json: Option<&Value>, path: &str) -> Result<Option<f64>, LoadError> {
        match json {
            None | Some(Value::Null) => Ok(None),
            Some(value) => value
                .as_f64()
                .map(Some)
                .ok_or_else(|| self.error(path, "must be a number")),
        }
    }
}

impl Scenario {
    /// Parses a scenario document; `file` names it in errors.
    pub fn parse(json: &Value, file: &str) -> Result<Scenario, LoadError> {
        let reader = Reader { file };
        let root = reader.object(
            Some(json),
            "$",
            &[
                "formatVersion",
                "name",
                "description",
                "reason",
                "source",
                "verifiedBy",
                "config",
                "script",
                "expect",
            ],
        )?;
        let version = reader.int(root.get("formatVersion"), "$.formatVersion")?;
        if version != 1 {
            return Err(reader.error(
                "$.formatVersion",
                &format!("this runner reads format 1, the file is format {version}"),
            ));
        }
        let name = reader.string(root.get("name"), "$.name")?;
        reader.string(root.get("description"), "$.description")?;
        reader.string(root.get("reason"), "$.reason")?;
        if let Some(source) = root.get("source") {
            reader.string(Some(source), "$.source")?;
        }
        reader.string_array(root.get("verifiedBy"), "$.verifiedBy")?;
        let config = parse_config(root.get("config"), &reader)?;
        let steps = match root.get("script") {
            Some(Value::Array(steps)) if !steps.is_empty() => steps,
            _ => return Err(reader.error("$.script", "must be a non-empty array of steps")),
        };
        let script = steps
            .iter()
            .enumerate()
            .map(|(index, step)| parse_step(step, index + 1, &reader))
            .collect::<Result<Vec<_>, _>>()?;
        check_acp_agents(&config, &script, &reader)?;
        if let Some(last) = script.last() {
            if !last.settle {
                return Err(reader.error(
                    &format!("$.script[{}].settle", last.number - 1),
                    "the last step has no next step to run before deferred work",
                ));
            }
        }
        let expect = parse_expectations(root.get("expect"), "$.expect", &reader)?;
        Ok(Scenario {
            file: file.to_owned(),
            name,
            config,
            script,
            expect,
        })
    }
}

fn parse_config(json: Option<&Value>, reader: &Reader) -> Result<Config, LoadError> {
    let Some(json) = json else {
        return Ok(Config::default());
    };
    let fields = reader.object(
        Some(json),
        "$.config",
        &[
            "harnessKind",
            "acpAgent",
            "acpCustomCommand",
            "model",
            "effort",
            "permissionMode",
            "controlMode",
            "project",
            "lastSessionID",
            "controllerConnected",
        ],
    )?;
    let string = |key: &str| reader.optional_string(fields.get(key), &format!("$.config.{key}"));
    Ok(Config {
        harness_kind: reader.harness_kind(fields.get("harnessKind"), "$.config.harnessKind")?,
        acp_agent: string("acpAgent")?,
        acp_custom_command: string("acpCustomCommand")?,
        model: string("model")?,
        effort: string("effort")?,
        permission_mode: string("permissionMode")?,
        control_mode: string("controlMode")?,
        project: reader
            .optional_bool(fields.get("project"), "$.config.project")?
            .unwrap_or(false),
        last_session_id: string("lastSessionID")?,
        controller_connected: reader
            .optional_bool(
                fields.get("controllerConnected"),
                "$.config.controllerConnected",
            )?
            .unwrap_or(false),
    })
}

/// A switchProject folder name: a lowercase letter, then letters, digits
/// or "-".
fn is_folder_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The protocol vocabulary (docs/protocol.md), as `IntentMapper` reads it.
/// Opening a window has no place in a test; voice capture is not in the
/// vocabulary.
fn protocol_intent(name: &str, text: Option<&str>) -> Option<Intent> {
    Some(match name {
        "sendPrompt" => {
            let text = powerup_core::text::trim(text?);
            if text.is_empty() {
                return None;
            }
            Intent::SendPrompt(text.to_owned())
        }
        "sendDraft" => Intent::SendDraft,
        "approve" => Intent::Approve,
        "reject" => Intent::Reject,
        "interrupt" => Intent::Interrupt,
        "stopSpeaking" => Intent::StopSpeaking,
        "replayLastReply" => Intent::ReplayLastReply,
        "toggleTTS" => Intent::ToggleTts,
        "newSession" => Intent::NewSession,
        "cycleModel" => Intent::CycleModel,
        "cycleEffort" => Intent::CycleEffort,
        "cyclePermissionMode" => Intent::CyclePermissionMode,
        "cycleProject" => Intent::CycleProject,
        "cycleFocus" => Intent::CycleFocus,
        "toggleControlMode" => Intent::ToggleControlMode,
        _ => return None,
    })
}

fn parse_step(json: &Value, number: usize, reader: &Reader) -> Result<Step, LoadError> {
    let path = format!("$.script[{}]", number - 1);
    let fields = reader.object(
        Some(json),
        &path,
        &[
            "call",
            "intent",
            "settings",
            "harnessEvent",
            "hookEvent",
            "advanceClock",
            "text",
            "allow",
            "project",
            "adapter",
            "reason",
            "expectNoChange",
            "settle",
            "expect",
        ],
    )?;
    if let Some(reason) = fields.get("reason") {
        reader.string(Some(reason), &format!("{path}.reason"))?;
    }
    let expect_no_change = reader
        .optional_bool(
            fields.get("expectNoChange"),
            &format!("{path}.expectNoChange"),
        )?
        .unwrap_or(false);
    let settle = reader
        .optional_bool(fields.get("settle"), &format!("{path}.settle"))?
        .unwrap_or(true);
    let expect = match fields.get("expect") {
        Some(expect) => Some(parse_expectations(
            Some(expect),
            &format!("{path}.expect"),
            reader,
        )?),
        None => None,
    };
    let kinds: Vec<&str> = [
        "call",
        "intent",
        "settings",
        "harnessEvent",
        "hookEvent",
        "advanceClock",
    ]
    .into_iter()
    .filter(|key| fields.contains_key(*key))
    .collect();
    if kinds.len() != 1 {
        return Err(reader.error(
            &path,
            "a step has exactly one of \"call\", \"intent\", \"settings\", \"harnessEvent\", \"hookEvent\" or \"advanceClock\"",
        ));
    }
    let text = reader.optional_string(fields.get("text"), &format!("{path}.text"))?;
    let allow = reader.optional_bool(fields.get("allow"), &format!("{path}.allow"))?;
    let project = reader.optional_string(fields.get("project"), &format!("{path}.project"))?;
    if !fields.contains_key("harnessEvent") && fields.contains_key("adapter") {
        return Err(reader.error(
            &format!("{path}.adapter"),
            "only a harnessEvent step names an adapter",
        ));
    }
    if project.is_some() && fields.get("call") != Some(&Value::from("switchProject")) {
        return Err(reader.error(&format!("{path}.project"), "not used by this step"));
    }
    let unused = |key: &str, present: bool| -> Result<(), LoadError> {
        if present {
            Err(reader.error(&format!("{path}.{key}"), "not used by this step"))
        } else {
            Ok(())
        }
    };

    let action = if let Some(call) = fields.get("call") {
        let name = reader.string(Some(call), &format!("{path}.call"))?;
        match name.as_str() {
            "startSessionIfNeeded" | "newSession" | "interruptClaude" => {
                unused("text", text.is_some())?;
                unused("allow", allow.is_some())?;
                Action::Call(match name.as_str() {
                    "startSessionIfNeeded" => CallStep::StartSessionIfNeeded,
                    "newSession" => CallStep::NewSession,
                    _ => CallStep::InterruptClaude,
                })
            }
            "sendUserText" => {
                let text = text.ok_or_else(|| {
                    reader.error(&format!("{path}.text"), "sendUserText needs \"text\"")
                })?;
                unused("allow", allow.is_some())?;
                Action::Call(CallStep::SendUserText(text))
            }
            "answerPendingPermission" => {
                let allow = allow.ok_or_else(|| {
                    reader.error(
                        &format!("{path}.allow"),
                        "answerPendingPermission needs \"allow\"",
                    )
                })?;
                unused("text", text.is_some())?;
                Action::Call(CallStep::AnswerPendingPermission(allow))
            }
            "switchProject" => {
                let project = project.ok_or_else(|| {
                    reader.error(
                        &format!("{path}.project"),
                        "switchProject needs \"project\"",
                    )
                })?;
                if !is_folder_name(&project) {
                    return Err(reader.error(
                        &format!("{path}.project"),
                        "a folder name: a lowercase letter, then letters, digits or \"-\"",
                    ));
                }
                unused("text", text.is_some())?;
                unused("allow", allow.is_some())?;
                Action::Call(CallStep::SwitchProject(project))
            }
            _ => {
                return Err(
                    reader.error(&format!("{path}.call"), &format!("unknown call \"{name}\""))
                )
            }
        }
    } else if let Some(intent) = fields.get("intent") {
        let name = reader.string(Some(intent), &format!("{path}.intent"))?;
        unused("allow", allow.is_some())?;
        let parsed = protocol_intent(&name, text.as_deref()).ok_or_else(|| {
            reader.error(
                &format!("{path}.intent"),
                &format!("unknown or unsupported intent \"{name}\""),
            )
        })?;
        if name != "sendPrompt" {
            unused("text", text.is_some())?;
        }
        Action::Intent(parsed)
    } else if let Some(settings) = fields.get("settings") {
        unused("text", text.is_some())?;
        unused("allow", allow.is_some())?;
        let settings_path = format!("{path}.settings");
        let change = reader.object(
            Some(settings),
            &settings_path,
            &["harnessKind", "acpAgent", "acpCustomCommand"],
        )?;
        if change.is_empty() {
            return Err(reader.error(&settings_path, "changes nothing"));
        }
        Action::Settings(SettingsChange {
            harness_kind: reader.harness_kind(
                change.get("harnessKind"),
                &format!("{settings_path}.harnessKind"),
            )?,
            acp_agent: reader
                .optional_string(change.get("acpAgent"), &format!("{settings_path}.acpAgent"))?,
            acp_custom_command: reader.optional_string(
                change.get("acpCustomCommand"),
                &format!("{settings_path}.acpCustomCommand"),
            )?,
        })
    } else if let Some(hook) = fields.get("hookEvent") {
        unused("text", text.is_some())?;
        unused("allow", allow.is_some())?;
        Action::HookEvent(parse_hook(hook, &format!("{path}.hookEvent"), reader)?)
    } else if let Some(seconds) = fields.get("advanceClock") {
        unused("text", text.is_some())?;
        unused("allow", allow.is_some())?;
        Action::AdvanceClock(reader.seconds(Some(seconds), &format!("{path}.advanceClock"))?)
    } else {
        unused("text", text.is_some())?;
        unused("allow", allow.is_some())?;
        let adapter = match reader
            .optional_string(fields.get("adapter"), &format!("{path}.adapter"))?
        {
            None => None,
            Some(name) => Some(match name.as_str() {
                "claude" => HarnessKind::Claude,
                "acp" => HarnessKind::Acp,
                _ => return Err(reader.error(&format!("{path}.adapter"), "\"claude\" or \"acp\"")),
            }),
        };
        let event = parse_event(
            fields.get("harnessEvent"),
            &format!("{path}.harnessEvent"),
            reader,
        )?;
        Action::HarnessEvent(event, adapter)
    };
    Ok(Step {
        number,
        action,
        expect_no_change,
        settle,
        expect,
        label: step_label(json),
    })
}

/// The step as printed in failures: its JSON without the checkpoint.
fn step_label(json: &Value) -> String {
    match json {
        Value::Object(fields) => {
            let mut fields = fields.clone();
            fields.remove("expect");
            describe(&Value::Object(fields))
        }
        other => describe(other),
    }
}

fn parse_event(
    json: Option<&Value>,
    path: &str,
    reader: &Reader,
) -> Result<HarnessEvent, LoadError> {
    let Some(Value::Object(fields)) = json else {
        return Err(reader.error(path, "must be an object with a \"type\""));
    };
    let Some(type_json) = fields.get("type") else {
        return Err(reader.error(path, "must be an object with a \"type\""));
    };
    let kind = reader.string(Some(type_json), &format!("{path}.type"))?;
    let keys = |allowed: &[&str]| -> Result<&Map<String, Value>, LoadError> {
        let mut all = allowed.to_vec();
        all.push("type");
        reader.object(json, path, &all)
    };
    let at = |key: &str| format!("{path}.{key}");
    Ok(match kind.as_str() {
        "sessionReady" => {
            let f = keys(&["sessionID", "model"])?;
            HarnessEvent::SessionReady {
                session_id: reader.string(f.get("sessionID"), &at("sessionID"))?,
                model: reader.string(f.get("model"), &at("model"))?,
            }
        }
        "replyDelta" => {
            let f = keys(&["text"])?;
            HarnessEvent::ReplyDelta(reader.string(f.get("text"), &at("text"))?)
        }
        "reply" => {
            let f = keys(&["text"])?;
            HarnessEvent::Reply(reader.string(f.get("text"), &at("text"))?)
        }
        "toolUse" => {
            let f = keys(&["name", "detail"])?;
            HarnessEvent::ToolUse {
                name: reader.string(f.get("name"), &at("name"))?,
                detail: reader.string(f.get("detail"), &at("detail"))?,
            }
        }
        "turnCompleted" => {
            let f = keys(&["resultText", "costUSD", "isError", "detail"])?;
            HarnessEvent::TurnCompleted {
                result_text: reader.optional_string(f.get("resultText"), &at("resultText"))?,
                cost_usd: reader.optional_double(f.get("costUSD"), &at("costUSD"))?,
                is_error: reader.bool(f.get("isError"), &at("isError"))?,
                detail: reader.string(f.get("detail"), &at("detail"))?,
            }
        }
        "controlResult" => {
            let f = keys(&["action", "ok", "detail", "value"])?;
            HarnessEvent::ControlResult {
                action: reader.string(f.get("action"), &at("action"))?,
                ok: reader.bool(f.get("ok"), &at("ok"))?,
                detail: reader.string(f.get("detail"), &at("detail"))?,
                value: reader.optional_string(f.get("value"), &at("value"))?,
            }
        }
        "permissionRequest" => {
            let f = keys(&["id", "name", "kind", "detail"])?;
            HarnessEvent::PermissionRequest {
                id: reader.string(f.get("id"), &at("id"))?,
                name: reader.string(f.get("name"), &at("name"))?,
                kind: reader.string(f.get("kind"), &at("kind"))?,
                detail: reader.string(f.get("detail"), &at("detail"))?,
            }
        }
        "notification" => {
            let f = keys(&["message"])?;
            HarnessEvent::Notification(reader.string(f.get("message"), &at("message"))?)
        }
        "runtimeError" => {
            let f = keys(&["message"])?;
            HarnessEvent::RuntimeError(reader.string(f.get("message"), &at("message"))?)
        }
        "ended" => {
            let f = keys(&["exitCode"])?;
            HarnessEvent::Ended {
                exit_code: reader.int(f.get("exitCode"), &at("exitCode"))?,
            }
        }
        _ => return Err(reader.error(&at("type"), &format!("unknown harness event \"{kind}\""))),
    })
}

fn parse_hook(json: &Value, path: &str, reader: &Reader) -> Result<ScriptedHook, LoadError> {
    let fields = reader.object(Some(json), path, &["type", "sessionID", "cwd", "text"])?;
    let kind_name = reader.string(fields.get("type"), &format!("{path}.type"))?;
    let kind = match kind_name.as_str() {
        "userPromptSubmit" => HookKind::UserPromptSubmit,
        "postToolUse" => HookKind::PostToolUse,
        "notification" => HookKind::Notification,
        "stop" => HookKind::Stop,
        "sessionEnd" => HookKind::SessionEnd,
        _ => {
            return Err(reader.error(
                &format!("{path}.type"),
                &format!(
                    "unknown hook event \"{kind_name}\" (allowed: notification, postToolUse, sessionEnd, stop, userPromptSubmit)"
                ),
            ))
        }
    };
    Ok(ScriptedHook {
        kind,
        text: reader.optional_string(fields.get("text"), &format!("{path}.text"))?,
        session_id: reader
            .optional_string(fields.get("sessionID"), &format!("{path}.sessionID"))?,
        cwd: reader.optional_string(fields.get("cwd"), &format!("{path}.cwd"))?,
    })
}

/// Whenever the script selects the ACP harness, the agent must be the
/// custom one, so the agent command never depends on the machine.
fn check_acp_agents(config: &Config, script: &[Step], reader: &Reader) -> Result<(), LoadError> {
    let mut kind = config
        .harness_kind
        .clone()
        .unwrap_or_else(|| "claude".into());
    let mut agent = config
        .acp_agent
        .clone()
        .unwrap_or_else(|| "opencode".into());
    let check = |kind: &str, agent: &str, path: &str| -> Result<(), LoadError> {
        if kind == "acp" && agent != "custom" {
            Err(reader.error(
                path,
                "the ACP harness needs \"acpAgent\": \"custom\" (with \"acpCustomCommand\"), so the agent command never depends on this machine",
            ))
        } else {
            Ok(())
        }
    };
    check(&kind, &agent, "$.config")?;
    for step in script {
        let Action::Settings(change) = &step.action else {
            continue;
        };
        if let Some(value) = &change.harness_kind {
            kind = value.clone();
        }
        if let Some(value) = &change.acp_agent {
            agent = value.clone();
        }
        check(
            &kind,
            &agent,
            &format!("$.script[{}].settings", step.number - 1),
        )?;
    }
    Ok(())
}

fn parse_list(
    json: &Value,
    path: &str,
    reader: &Reader,
    types: fn(&str) -> Option<&'static [&'static str]>,
    what: &str,
    extra: &[&str],
) -> Result<Vec<Map<String, Value>>, LoadError> {
    let Value::Array(items) = json else {
        return Err(reader.error(path, "must be an array"));
    };
    items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let item_path = format!("{path}[{index}]");
            let type_json = match item {
                Value::Object(object) => object.get("type"),
                _ => None,
            }
            .ok_or_else(|| reader.error(&item_path, "must be an object with a \"type\""))?;
            let kind = reader.string(Some(type_json), &format!("{item_path}.type"))?;
            let allowed = types(&kind).ok_or_else(|| {
                reader.error(
                    &format!("{item_path}.type"),
                    &format!("unknown {what} \"{kind}\""),
                )
            })?;
            let mut keys = allowed.to_vec();
            keys.push("type");
            keys.extend_from_slice(extra);
            let object = reader.object(Some(item), &item_path, &keys)?;
            if let Some(adapter) = object.get("adapter") {
                let name = reader.string(Some(adapter), &format!("{item_path}.adapter"))?;
                if !HARNESS_KINDS.contains(&name.as_str()) {
                    return Err(
                        reader.error(&format!("{item_path}.adapter"), "\"claude\" or \"acp\"")
                    );
                }
            }
            Ok(object.clone())
        })
        .collect()
}

fn parse_expectations(
    json: Option<&Value>,
    root: &str,
    reader: &Reader,
) -> Result<Expectations, LoadError> {
    let Some(json) = json else {
        return Err(reader.error(root, "missing"));
    };
    let fields = reader.object(
        Some(json),
        root,
        &[
            "harnessCalls",
            "transcript",
            "errorShown",
            "lastSessionID",
            "pendingPermission",
            "pendingPermissionArmed",
            "status",
            "liveModel",
            "modelChip",
            "remoteTurnActive",
            "remoteFocus",
            "injectorCalls",
            "permissionMode",
            "liveSessionID",
            "lastAssistantReply",
        ],
    )?;
    if fields.is_empty() {
        return Err(reader.error(root, "expects nothing"));
    }
    let at = |key: &str| format!("{root}.{key}");
    let mut expect = Expectations::default();
    if let Some(calls) = fields.get("harnessCalls") {
        expect.harness_calls = Some(parse_list(
            calls,
            &at("harnessCalls"),
            reader,
            call_type_keys,
            "harness call",
            &["adapter"],
        )?);
    }
    if let Some(transcript) = fields.get("transcript") {
        let Value::Array(items) = transcript else {
            return Err(reader.error(&at("transcript"), "must be an array"));
        };
        let mut entries = Vec::new();
        for (index, item) in items.iter().enumerate() {
            let path = format!("{}[{index}]", at("transcript"));
            let object = reader.object(Some(item), &path, &["kind", "text"])?;
            let kind = reader.string(object.get("kind"), &format!("{path}.kind"))?;
            if !TRANSCRIPT_KINDS.contains(&kind.as_str()) {
                return Err(reader.error(
                    &format!("{path}.kind"),
                    &format!("unknown entry kind \"{kind}\""),
                ));
            }
            if let Some(text) = object.get("text") {
                reader.string(Some(text), &format!("{path}.text"))?;
            }
            entries.push(object.clone());
        }
        expect.transcript = Some(entries);
    }
    expect.error_shown = reader.optional_bool(fields.get("errorShown"), &at("errorShown"))?;
    let optional_id = |key: &str| -> Result<Option<Option<String>>, LoadError> {
        fields
            .get(key)
            .map(|value| reader.optional_string(Some(value), &at(key)))
            .transpose()
    };
    expect.last_session_id = optional_id("lastSessionID")?;
    expect.pending_permission =
        reader.optional_bool(fields.get("pendingPermission"), &at("pendingPermission"))?;
    expect.pending_permission_armed = reader.optional_bool(
        fields.get("pendingPermissionArmed"),
        &at("pendingPermissionArmed"),
    )?;
    if let Some(status) = fields.get("status") {
        let name = reader.string(Some(status), &at("status"))?;
        if !STATUS_NAMES.contains(&name.as_str()) {
            return Err(reader.error(&at("status"), &format!("unknown status \"{name}\"")));
        }
        expect.status = Some(name);
    }
    expect.live_model = optional_id("liveModel")?;
    expect.model_chip = reader.optional_string(fields.get("modelChip"), &at("modelChip"))?;
    expect.remote_turn_active =
        reader.optional_bool(fields.get("remoteTurnActive"), &at("remoteTurnActive"))?;
    expect.remote_focus = optional_id("remoteFocus")?;
    expect.permission_mode =
        reader.optional_string(fields.get("permissionMode"), &at("permissionMode"))?;
    expect.live_session_id = optional_id("liveSessionID")?;
    expect.last_assistant_reply = optional_id("lastAssistantReply")?;
    if let Some(calls) = fields.get("injectorCalls") {
        expect.injector_calls = Some(parse_list(
            calls,
            &at("injectorCalls"),
            reader,
            injector_type_keys,
            "injector call",
            &[],
        )?);
    }
    Ok(expect)
}

// MARK: - The world

/// A scripted harness, following the real adapters' own state as the
/// README's "scripted harnesses" paragraph describes.
#[derive(Debug, Clone)]
struct FakeHarness {
    state: HarnessState,
    session_id: Option<String>,
    model_name: Option<String>,
    total_cost_usd: f64,
    supports_effort: bool,
    clears_session_id_on_stop: bool,
}

impl FakeHarness {
    fn new(supports_effort: bool, clears_session_id_on_stop: bool) -> FakeHarness {
        FakeHarness {
            state: HarnessState::Stopped,
            session_id: None,
            model_name: None,
            total_cost_usd: 0.0,
            supports_effort,
            clears_session_id_on_stop,
        }
    }

    fn snapshot(&self) -> HarnessSnapshot {
        HarnessSnapshot {
            state: self.state,
            session_id: self.session_id.clone(),
            model_name: self.model_name.clone(),
            supports_effort: self.supports_effort,
        }
    }

    /// What the real adapter's own state does on reporting `event`, before
    /// the session sees it.
    fn apply(&mut self, event: &HarnessEvent) {
        match event {
            HarnessEvent::SessionReady { session_id, model } => {
                self.session_id = Some(session_id.clone());
                self.model_name = Some(model.clone());
                if self.state != HarnessState::Working {
                    self.state = HarnessState::Ready;
                }
            }
            HarnessEvent::TurnCompleted { cost_usd, .. } => {
                if let Some(cost) = cost_usd {
                    self.total_cost_usd = *cost;
                }
                if self.state != HarnessState::Stopped {
                    self.state = HarnessState::Ready;
                }
            }
            HarnessEvent::ControlResult {
                action, ok, value, ..
            } => {
                if let (true, "set_model", Some(value)) = (*ok, action.as_str(), value) {
                    if !value.is_empty() {
                        self.model_name = Some(value.clone());
                    }
                }
            }
            HarnessEvent::Ended { .. } => {
                self.state = HarnessState::Stopped;
                self.session_id = None;
            }
            _ => {}
        }
    }
}

#[derive(Debug, Clone)]
struct Entry {
    id: u64,
    kind: TranscriptKind,
    text: String,
}

fn kind_name(kind: TranscriptKind) -> &'static str {
    match kind {
        TranscriptKind::User => "user",
        TranscriptKind::Assistant => "assistant",
        TranscriptKind::Tool => "tool",
        TranscriptKind::System => "system",
        TranscriptKind::Error => "error",
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Observation {
    harness_calls: Vec<Map<String, Value>>,
    transcript: Vec<Map<String, Value>>,
    last_session_id: Option<String>,
    pending_permission: bool,
    pending_permission_armed: bool,
    status: String,
    live_model: Option<String>,
    model_chip: String,
    remote_turn_active: bool,
    remote_focus: Option<String>,
    injector_calls: Vec<Map<String, Value>>,
    permission_mode: String,
    live_session_id: Option<String>,
    last_assistant_reply: Option<String>,
}

struct World {
    settings: SessionSettings,
    controller_connected: bool,
    claude: FakeHarness,
    acp: FakeHarness,
    calls: Vec<Map<String, Value>>,
    // The transcript.
    next_entry_id: u64,
    scrollback: Vec<Entry>,
    stores: BTreeMap<String, Vec<Entry>>,
    store_project: Option<String>,
    seen: BTreeSet<u64>,
    appeared: Vec<Map<String, Value>>,
    // Remote mode and the published mirrors.
    injector: Vec<Map<String, Value>>,
    pending: Option<PendingPermission>,
    remote_turn_active: bool,
    remote_focus: Option<String>,
    last_assistant_reply: Option<String>,
    live_reply: String,
    // Time.
    now: f64,
    timers: Vec<(f64, usize)>,
    next_timer: usize,
    deferred: VecDeque<()>,
    folders: BTreeSet<String>,
}

fn sandbox_path(name: &str) -> String {
    format!("{SANDBOX}/{name}")
}

/// `$name` for a sandbox folder, the path itself otherwise.
fn label(path: &str) -> String {
    match path.strip_prefix(&format!("{SANDBOX}/")) {
        Some(name) if !name.is_empty() && !name.contains('/') => format!("${name}"),
        _ => path.to_owned(),
    }
}

/// A path as the Swift app would place it: the virtual sandbox has no
/// symlinks, so standardizing and resolving leave it as it is.
fn place(path: &str) -> PlacedPath {
    assert!(
        path.starts_with('/'),
        "a scenario path must be absolute: {path:?}"
    );
    let parts: Vec<String> = path
        .split('/')
        .filter(|part| !part.is_empty())
        .map(str::to_owned)
        .collect();
    let mut components = vec!["/".to_owned()];
    components.extend(parts.iter().cloned());
    let standardized = if parts.is_empty() {
        "/".to_owned()
    } else {
        format!("/{}", parts.join("/"))
    };
    let name = parts.last().cloned().unwrap_or_else(|| "/".to_owned());
    PlacedPath {
        components,
        standardized,
        name,
    }
}

fn default_settings() -> SessionSettings {
    // AppConfig.defaultConfig()'s values for the fields the session reads.
    SessionSettings {
        harness_kind: "claude".to_owned(),
        acp_agent: "opencode".to_owned(),
        acp_custom_command: String::new(),
        control_mode: "builtin".to_owned(),
        model: "default".to_owned(),
        model_cycle: powerup_core::session::cycles::DEFAULT_MODEL_CYCLE
            .iter()
            .map(|&m| m.to_owned())
            .collect(),
        effort: "default".to_owned(),
        permission_mode: "acceptEdits".to_owned(),
        project_dir: None,
        last_session_id: None,
        session_ids_by_project: BTreeMap::new(),
        recent_project_dirs: Vec::new(),
        claude_path: None,
        remote_auto_submit: true,
    }
}

impl World {
    fn new(config: &Config) -> World {
        let mut settings = default_settings();
        let set = |target: &mut String, value: &Option<String>| {
            if let Some(value) = value {
                target.clone_from(value);
            }
        };
        set(&mut settings.harness_kind, &config.harness_kind);
        set(&mut settings.acp_agent, &config.acp_agent);
        set(&mut settings.acp_custom_command, &config.acp_custom_command);
        set(&mut settings.model, &config.model);
        set(&mut settings.effort, &config.effort);
        set(&mut settings.permission_mode, &config.permission_mode);
        set(&mut settings.control_mode, &config.control_mode);
        settings.last_session_id.clone_from(&config.last_session_id);
        let mut folders = BTreeSet::new();
        if config.project {
            let dir = sandbox_path("project");
            folders.insert(dir.clone());
            settings.project_dir = Some(dir.clone());
            // AppState's launch seeding (seedProjectBookkeeping): the
            // folder joins the recents and adopts the stored id.
            settings.recent_project_dirs.insert(0, dir.clone());
            if let Some(last) = &settings.last_session_id {
                settings.session_ids_by_project.insert(dir, last.clone());
            }
        }
        World {
            store_project: settings.project_dir.clone(),
            settings,
            controller_connected: config.controller_connected,
            claude: FakeHarness::new(true, false),
            acp: FakeHarness::new(false, true),
            calls: Vec::new(),
            next_entry_id: 0,
            scrollback: Vec::new(),
            stores: BTreeMap::new(),
            seen: BTreeSet::new(),
            appeared: Vec::new(),
            injector: Vec::new(),
            pending: None,
            remote_turn_active: false,
            remote_focus: None,
            last_assistant_reply: None,
            live_reply: String::new(),
            now: CLOCK_START,
            timers: Vec::new(),
            next_timer: 0,
            deferred: VecDeque::new(),
            folders,
        }
    }

    fn active_kind(&self) -> HarnessKind {
        HarnessKind::from_setting(&self.settings.harness_kind)
    }

    fn fake(&mut self, kind: HarnessKind) -> &mut FakeHarness {
        match kind {
            HarnessKind::Claude => &mut self.claude,
            HarnessKind::Acp => &mut self.acp,
        }
    }

    fn active(&self) -> &FakeHarness {
        match self.active_kind() {
            HarnessKind::Claude => &self.claude,
            HarnessKind::Acp => &self.acp,
        }
    }

    fn context(&self) -> SessionContext {
        let acp_agent_command = (self.active_kind() == HarnessKind::Acp).then(|| {
            assert_eq!(
                self.settings.acp_agent, "custom",
                "the runner resolves only the custom agent's command"
            );
            self.settings
                .acp_custom_command
                .split(' ')
                .filter(|part| !part.is_empty())
                .map(str::to_owned)
                .collect::<Vec<_>>()
        });
        SessionContext {
            settings: self.settings.clone(),
            claude: self.claude.snapshot(),
            acp: Some(self.acp.snapshot()),
            acp_agent_command: acp_agent_command.filter(|command| !command.is_empty()),
            now: self.now,
        }
    }

    fn folder(&mut self, name: &str) -> String {
        let path = sandbox_path(name);
        self.folders.insert(path.clone());
        path
    }

    /// A hook's cwd as written: `$name` is that sandbox folder, `$name/sub`
    /// a folder below it.
    fn hook_path(&mut self, written: &str) -> String {
        let Some(rest) = written.strip_prefix('$') else {
            return written.to_owned();
        };
        let (name, below) = match rest.split_once('/') {
            Some((name, below)) => (name, Some(below)),
            None => (rest, None),
        };
        let folder = self.folder(name);
        match below {
            Some(below) => format!("{folder}/{below}"),
            None => folder,
        }
    }

    fn record_call(&mut self, kind: HarnessKind, mut call: Map<String, Value>) {
        call.insert("adapter".into(), kind.name().into());
        self.calls.push(call);
    }

    fn append_entry(&mut self, kind: TranscriptKind, text: &str) {
        // AppState.appendEntry: trimmed, and dropped when empty.
        let trimmed = powerup_core::text::trim(text);
        if trimmed.is_empty() {
            return;
        }
        self.next_entry_id += 1;
        let entry = Entry {
            id: self.next_entry_id,
            kind,
            text: trimmed.to_owned(),
        };
        if let Some(project) = &self.store_project {
            self.stores
                .entry(project.clone())
                .or_default()
                .push(entry.clone());
        }
        self.scrollback.push(entry);
    }

    /// AppState.restorePersistedTranscript: the folder's stored tail (200),
    /// topped with a marker that is never stored.
    fn restore_history(&mut self) {
        let Some(project) = &self.store_project else {
            return;
        };
        let stored = self.stores.get(project).cloned().unwrap_or_default();
        if stored.is_empty() {
            return;
        }
        let mut restored: Vec<Entry> = stored[stored.len().saturating_sub(200)..].to_vec();
        self.next_entry_id += 1;
        restored.push(Entry {
            id: self.next_entry_id,
            kind: TranscriptKind::System,
            text: "Earlier conversation restored — New Session starts clean.".to_owned(),
        });
        self.scrollback = restored;
    }

    fn apply_config(&mut self, change: ConfigChange) {
        let settings = &mut self.settings;
        match change {
            ConfigChange::Model(value) => settings.model = value,
            ConfigChange::Effort(value) => settings.effort = value,
            ConfigChange::PermissionMode(value) => settings.permission_mode = value,
            ConfigChange::ControlMode(value) => settings.control_mode = value,
            ConfigChange::ProjectDir(path) => settings.project_dir = Some(path),
            ConfigChange::LastSessionId(id) => settings.last_session_id = id,
            ConfigChange::ProjectSessionId {
                project_dir,
                session_id,
            } => match session_id {
                Some(id) => {
                    settings.session_ids_by_project.insert(project_dir, id);
                }
                None => {
                    settings.session_ids_by_project.remove(&project_dir);
                }
            },
            ConfigChange::RecentProjectDirs(paths) => settings.recent_project_dirs = paths,
        }
    }

    /// Carries out the machine's effects in order, as AppState does.
    fn execute(&mut self, machine: &mut SessionMachine, effects: Vec<SessionEffect>) {
        for effect in effects {
            match effect {
                SessionEffect::StartHarness {
                    harness,
                    configuration,
                } => self.start(harness, configuration),
                SessionEffect::SendToHarness { harness, text } => {
                    if self.fake(harness).state == HarnessState::Stopped {
                        let refused = machine.send_refused(&self.context());
                        self.execute(machine, refused);
                    } else {
                        self.fake(harness).state = HarnessState::Working;
                        let call = serde_json::json!({"type": "send", "text": text});
                        self.record_call(harness, object(call));
                    }
                }
                SessionEffect::InterruptHarness { harness } => {
                    self.record_call(harness, object(serde_json::json!({"type": "interrupt"})));
                }
                SessionEffect::SetHarnessModel { harness, model } => {
                    let call = serde_json::json!({"type": "setModel", "model": model});
                    self.record_call(harness, object(call));
                }
                SessionEffect::SetHarnessPermissionMode { harness, mode } => {
                    let call = serde_json::json!({"type": "setPermissionMode", "mode": mode});
                    self.record_call(harness, object(call));
                }
                SessionEffect::AnswerPermission { harness, id, allow } => {
                    let call = serde_json::json!({"type": "respondToPermission", "id": id, "allow": allow});
                    self.record_call(harness, object(call));
                }
                SessionEffect::StopHarness { harness } => {
                    let fake = self.fake(harness);
                    fake.state = HarnessState::Stopped;
                    if fake.clears_session_id_on_stop {
                        fake.session_id = None;
                    }
                    self.record_call(harness, object(serde_json::json!({"type": "stop"})));
                }
                SessionEffect::ChangeConfig(change) => self.apply_config(change),
                SessionEffect::AppendTranscript { kind, text } => self.append_entry(kind, &text),
                SessionEffect::ShowProjectTranscript {
                    project_dir,
                    restore_history,
                } => {
                    self.store_project = Some(project_dir).filter(|dir| !dir.is_empty());
                    if restore_history {
                        self.scrollback.clear();
                        self.restore_history();
                    }
                }
                SessionEffect::AppendLiveReply(text) => self.live_reply.push_str(&text),
                SessionEffect::ClearLiveReply => self.live_reply.clear(),
                SessionEffect::SetLastReply(text) => self.last_assistant_reply = Some(text),
                SessionEffect::PendingPermissionChanged(pending) => self.pending = pending,
                SessionEffect::RemoteTurnActiveChanged(active) => self.remote_turn_active = active,
                SessionEffect::RemoteFocusChanged(focus) => self.remote_focus = focus,
                SessionEffect::InjectText { text, submit } => {
                    // Flattening line breaks is the remote service's rule
                    // (slice 2.5); no scenario types one.
                    assert!(
                        !text.contains(['\n', '\r']),
                        "remote text with a line break needs the remote service's flattening: {text:?}"
                    );
                    self.injector.push(object(
                        serde_json::json!({"type": "text", "text": text, "submit": submit}),
                    ));
                }
                SessionEffect::InjectKey(key) => {
                    let name = match key {
                        RemoteKey::Enter => "enter",
                        RemoteKey::Escape => "escape",
                        RemoteKey::ShiftTab => "shiftTab",
                    };
                    self.injector
                        .push(object(serde_json::json!({"type": "key", "key": name})));
                }
                SessionEffect::ScheduleRemoteTurnCheck { after_seconds } => {
                    self.timers
                        .push((self.now + after_seconds.max(0.0), self.next_timer));
                    self.next_timer += 1;
                }
                SessionEffect::DeferEffortRestart => self.deferred.push_back(()),
                // Feedback and the status pill: spoken replies are off in a
                // scenario, and the status is derived when it is observed.
                SessionEffect::Haptic { .. }
                | SessionEffect::ErrorHaptic
                | SessionEffect::Announce(_)
                | SessionEffect::SpeakReply(_)
                | SessionEffect::CancelSummary
                | SessionEffect::StopSpeaking
                | SessionEffect::RefreshRemoteStatus
                | SessionEffect::UpdateStatus => {}
            }
        }
    }

    fn start(&mut self, harness: HarnessKind, configuration: HarnessConfiguration) {
        let optional = |value: &Option<String>| value.clone().map_or(Value::Null, Value::from);
        let call = serde_json::json!({
            "type": "start",
            "projectDir": label(&configuration.project_dir),
            "model": configuration.model,
            "permissionMode": configuration.permission_mode,
            "effort": configuration.effort,
            "resumeSessionID": optional(&configuration.resume_session_id),
            "binaryPathOverride": optional(&configuration.binary_path_override),
            "agentCommand": configuration.agent_command.clone().map_or(Value::Null, Value::from),
        });
        let fake = self.fake(harness);
        fake.session_id = configuration.resume_session_id;
        fake.model_name = None;
        fake.state = HarnessState::Starting;
        self.record_call(harness, object(call));
    }

    /// The deferred hops, then the derived-update pass, as the Swift
    /// runner's settle gives AppState its main-actor turns.
    fn settle(&mut self, machine: &mut SessionMachine) {
        loop {
            while self.deferred.pop_front().is_some() {
                let effects = machine.deferred_effort_restart(&self.context());
                self.execute(machine, effects);
            }
            let effects = machine.sync_settings(&self.context());
            self.execute(machine, effects);
            if self.deferred.is_empty() {
                break;
            }
        }
    }

    fn advance_clock(&mut self, machine: &mut SessionMachine, seconds: f64) {
        let target = self.now + seconds.max(0.0);
        loop {
            let due = self
                .timers
                .iter()
                .enumerate()
                .filter(|(_, (due, _))| *due <= target)
                .min_by(|(_, a), (_, b)| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)))
                .map(|(index, _)| index);
            let Some(index) = due else {
                break;
            };
            let (due, _) = self.timers.remove(index);
            self.now = due;
            let effects = machine.remote_turn_check(&self.context());
            self.execute(machine, effects);
        }
        self.now = target;
    }

    fn perform(&mut self, machine: &mut SessionMachine, action: &Action) {
        match action {
            Action::HarnessEvent(event, adapter) => {
                let from = adapter.unwrap_or_else(|| {
                    if self.settings.harness_kind == "acp" {
                        HarnessKind::Acp
                    } else {
                        HarnessKind::Claude
                    }
                });
                self.fake(from).apply(event);
                let effects = machine.harness_event(&self.context(), from, event.clone());
                self.execute(machine, effects);
            }
            Action::Settings(change) => {
                let settings = &mut self.settings;
                if let Some(value) = &change.harness_kind {
                    settings.harness_kind.clone_from(value);
                }
                if let Some(value) = &change.acp_agent {
                    settings.acp_agent.clone_from(value);
                }
                if let Some(value) = &change.acp_custom_command {
                    settings.acp_custom_command.clone_from(value);
                }
            }
            Action::HookEvent(hook) => {
                let cwd = hook.cwd.as_deref().map(|cwd| self.hook_path(cwd));
                let event = HookEvent {
                    kind: hook.kind,
                    text: hook.text.clone(),
                    session_id: hook.session_id.clone(),
                    cwd_place: cwd.as_deref().filter(|cwd| !cwd.is_empty()).map(place),
                    cwd,
                };
                let project = self
                    .settings
                    .project_dir
                    .as_deref()
                    .filter(|dir| !dir.is_empty())
                    .map(place);
                let effects = machine.hook_event(&self.context(), &event, project.as_ref());
                self.execute(machine, effects);
            }
            Action::AdvanceClock(seconds) => self.advance_clock(machine, *seconds),
            Action::Intent(intent) => {
                let effects = machine.handle_intent(&self.context(), intent);
                self.execute(machine, effects);
                // The intents the platform runs itself.
                match intent {
                    Intent::CycleProject => {
                        let existing: Vec<String> = self
                            .settings
                            .recent_project_dirs
                            .iter()
                            .filter(|dir| self.folders.contains(*dir))
                            .cloned()
                            .collect();
                        let effects = machine.cycle_project(&self.context(), &existing);
                        self.execute(machine, effects);
                    }
                    // Nothing a scenario observes with spoken replies off.
                    Intent::StopSpeaking => {}
                    Intent::SendDraft | Intent::ReplayLastReply | Intent::ToggleTts => {
                        panic!(
                            "{} is run by the platform; this runner does not play it",
                            intent.name()
                        )
                    }
                    _ => {}
                }
            }
            Action::Call(call) => {
                let ctx = self.context();
                let effects = match call {
                    CallStep::StartSessionIfNeeded => machine.start_session_if_needed(&ctx),
                    CallStep::NewSession => machine.new_session(&ctx),
                    CallStep::SendUserText(text) => machine.send_user_text(&ctx, text),
                    CallStep::InterruptClaude => machine.interrupt(&ctx),
                    CallStep::AnswerPendingPermission(allow) => {
                        machine.answer_pending_permission(&ctx, *allow)
                    }
                    CallStep::SwitchProject(name) => {
                        let path = self.folder(name);
                        machine.switch_project(&ctx, &path)
                    }
                };
                self.execute(machine, effects);
            }
        }
    }

    fn observe(&mut self, machine: &SessionMachine) -> Observation {
        // The published mirrors are what the views read; they must agree
        // with the machine's own answers.
        assert_eq!(self.pending.as_ref(), machine.pending_permission());
        assert_eq!(self.remote_turn_active, machine.remote_turn_active());
        assert_eq!(self.remote_focus.as_deref(), machine.remote_focus());
        for entry in &self.scrollback {
            if self.seen.insert(entry.id) {
                self.appeared.push(object(serde_json::json!({
                    "kind": kind_name(entry.kind),
                    "text": entry.text,
                })));
            }
        }
        let remote = powerup_core::session::cycles::is_remote_mode(&self.settings.control_mode);
        let active = self.active();
        let working = derived_is_working(active.state, remote, self.remote_turn_active);
        Observation {
            harness_calls: self.calls.clone(),
            transcript: self.appeared.clone(),
            last_session_id: self.settings.last_session_id.clone(),
            pending_permission: self.pending.is_some(),
            pending_permission_armed: self.pending.as_ref().is_some_and(|p| p.armed),
            status: derived_status(self.controller_connected, false, false, working)
                .name()
                .to_owned(),
            live_model: active.model_name.clone(),
            model_chip: model_chip_label(&self.settings.model, active.model_name.as_deref()),
            remote_turn_active: self.remote_turn_active,
            remote_focus: self.remote_focus.clone(),
            injector_calls: self.injector.clone(),
            permission_mode: self.settings.permission_mode.clone(),
            live_session_id: active.session_id.clone(),
            last_assistant_reply: self.last_assistant_reply.clone(),
        }
    }
}

fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

// MARK: - Comparing

/// A JSON value as the Swift runner prints it: object keys sorted, a
/// space after each separator, integral numbers without a fraction.
fn describe(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => {
            let value = number.as_f64().unwrap_or(f64::NAN);
            if value.round() == value && value.abs() < 1e15 {
                #[allow(clippy::cast_possible_truncation)]
                let integral = value as i64;
                integral.to_string()
            } else {
                value.to_string()
            }
        }
        Value::String(text) => format!("\"{text}\""),
        Value::Array(items) => format!(
            "[{}]",
            items.iter().map(describe).collect::<Vec<_>>().join(", ")
        ),
        Value::Object(fields) => {
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys
                .into_iter()
                .map(|key| format!("\"{key}\": {}", describe(&fields[key])))
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
    }
}

/// JSON equality with numbers compared as numbers, as Swift's parsed
/// values compare.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn optional_text(value: &Option<String>) -> String {
    value
        .as_ref()
        .map_or_else(|| "null".to_owned(), |text| format!("\"{text}\""))
}

fn first_difference(before: &Observation, after: &Observation) -> Option<String> {
    let added = |b: &[Map<String, Value>], a: &[Map<String, Value>]| {
        a.iter()
            .skip(b.len())
            .map(|entry| describe(&Value::Object(entry.clone())))
            .collect::<Vec<_>>()
            .join(", ")
    };
    if before.harness_calls != after.harness_calls {
        return Some(format!(
            "harnessCalls (recorded {})",
            added(&before.harness_calls, &after.harness_calls)
        ));
    }
    if before.transcript != after.transcript {
        return Some(format!(
            "transcript (appended {})",
            added(&before.transcript, &after.transcript)
        ));
    }
    let text = |name: &str, b: &Option<String>, a: &Option<String>| {
        (b != a).then(|| format!("{name} ({} → {})", optional_text(b), optional_text(a)))
    };
    let plain = |name: &str, b: String, a: String| (b != a).then(|| format!("{name} ({b} → {a})"));
    text(
        "lastSessionID",
        &before.last_session_id,
        &after.last_session_id,
    )
    .or_else(|| {
        plain(
            "pendingPermission",
            before.pending_permission.to_string(),
            after.pending_permission.to_string(),
        )
    })
    .or_else(|| {
        plain(
            "pendingPermissionArmed",
            before.pending_permission_armed.to_string(),
            after.pending_permission_armed.to_string(),
        )
    })
    .or_else(|| plain("status", before.status.clone(), after.status.clone()))
    .or_else(|| text("liveModel", &before.live_model, &after.live_model))
    .or_else(|| {
        plain(
            "modelChip",
            before.model_chip.clone(),
            after.model_chip.clone(),
        )
    })
    .or_else(|| {
        plain(
            "remoteTurnActive",
            before.remote_turn_active.to_string(),
            after.remote_turn_active.to_string(),
        )
    })
    .or_else(|| text("remoteFocus", &before.remote_focus, &after.remote_focus))
    .or_else(|| {
        plain(
            "permissionMode",
            before.permission_mode.clone(),
            after.permission_mode.clone(),
        )
    })
    .or_else(|| {
        text(
            "liveSessionID",
            &before.live_session_id,
            &after.live_session_id,
        )
    })
    .or_else(|| {
        text(
            "lastAssistantReply",
            &before.last_assistant_reply,
            &after.last_assistant_reply,
        )
    })
    .or_else(|| {
        (before.injector_calls != after.injector_calls).then(|| {
            format!(
                "injectorCalls (recorded {})",
                added(&before.injector_calls, &after.injector_calls)
            )
        })
    })
}

/// Each mismatch as "<root>.<path>: expected …, got …". Lists compare
/// element by element on the keys the expectation writes.
fn compare(expect: &Expectations, actual: &Observation, root: &str) -> Vec<String> {
    let mut failures = Vec::new();
    let mut compare_list =
        |name: &str, expected: &[Map<String, Value>], actual: &[Map<String, Value>]| {
            for (index, wanted) in expected.iter().enumerate() {
                let Some(got) = actual.get(index) else {
                    failures.push(format!(
                        "{root}.{name}[{index}]: expected {}, got nothing (only {} recorded)",
                        describe(&Value::Object(wanted.clone())),
                        actual.len()
                    ));
                    return;
                };
                let mut keys: Vec<&String> = wanted.keys().collect();
                keys.sort();
                for key in keys {
                    let matches = got.get(key).is_some_and(|value| same(&wanted[key], value));
                    if !matches {
                        failures.push(format!(
                            "{root}.{name}[{index}].{key}: expected {}, got {} — full entry {}",
                            describe(&wanted[key]),
                            got.get(key).map_or_else(|| "null".to_owned(), describe),
                            describe(&Value::Object(got.clone()))
                        ));
                        return;
                    }
                }
            }
            if actual.len() > expected.len() {
                let extra: Vec<String> = actual[expected.len()..]
                    .iter()
                    .map(|entry| describe(&Value::Object(entry.clone())))
                    .collect();
                failures.push(format!(
                    "{root}.{name}: expected {} entries, got {}; unexpected {}",
                    expected.len(),
                    actual.len(),
                    extra.join(", ")
                ));
            }
        };
    if let Some(calls) = &expect.harness_calls {
        compare_list("harnessCalls", calls, &actual.harness_calls);
    }
    if let Some(calls) = &expect.injector_calls {
        compare_list("injectorCalls", calls, &actual.injector_calls);
    }
    if let Some(transcript) = &expect.transcript {
        compare_list("transcript", transcript, &actual.transcript);
    }
    if let Some(error_shown) = expect.error_shown {
        let shown = actual
            .transcript
            .iter()
            .any(|entry| entry.get("kind") == Some(&Value::from("error")));
        if shown != error_shown {
            failures.push(format!(
                "{root}.errorShown: expected {error_shown}, got {shown}"
            ));
        }
    }
    let mut text = |name: &str, wanted: &Option<Option<String>>, got: &Option<String>| {
        if let Some(wanted) = wanted {
            if wanted != got {
                failures.push(format!(
                    "{root}.{name}: expected {}, got {}",
                    optional_text(wanted),
                    optional_text(got)
                ));
            }
        }
    };
    text(
        "lastSessionID",
        &expect.last_session_id,
        &actual.last_session_id,
    );
    text("liveModel", &expect.live_model, &actual.live_model);
    text("remoteFocus", &expect.remote_focus, &actual.remote_focus);
    text(
        "liveSessionID",
        &expect.live_session_id,
        &actual.live_session_id,
    );
    text(
        "lastAssistantReply",
        &expect.last_assistant_reply,
        &actual.last_assistant_reply,
    );
    let mut flag = |name: &str, wanted: Option<bool>, got: bool| {
        if let Some(wanted) = wanted {
            if wanted != got {
                failures.push(format!("{root}.{name}: expected {wanted}, got {got}"));
            }
        }
    };
    flag(
        "pendingPermission",
        expect.pending_permission,
        actual.pending_permission,
    );
    flag(
        "pendingPermissionArmed",
        expect.pending_permission_armed,
        actual.pending_permission_armed,
    );
    flag(
        "remoteTurnActive",
        expect.remote_turn_active,
        actual.remote_turn_active,
    );
    let mut name = |key: &str, wanted: &Option<String>, got: &str| {
        if let Some(wanted) = wanted {
            if wanted != got {
                failures.push(format!(
                    "{root}.{key}: expected \"{wanted}\", got \"{got}\""
                ));
            }
        }
    };
    name("status", &expect.status, &actual.status);
    name("modelChip", &expect.model_chip, &actual.model_chip);
    name(
        "permissionMode",
        &expect.permission_mode,
        &actual.permission_mode,
    );
    failures
}

// MARK: - Running

/// Plays a scenario and returns every mismatch, each prefixed with the
/// scenario's name and file. An empty result means it passed.
pub fn run(scenario: &Scenario) -> Vec<String> {
    let prefix = format!("[{}] ({})", scenario.name, scenario.file);
    let mut world = World::new(&scenario.config);
    let mut machine = SessionMachine::new(&world.settings);
    world.settle(&mut machine);
    // Facts are measured from here: nothing the launch did is part of the
    // script.
    world.calls.clear();
    world.injector.clear();
    world.observe(&machine);
    world.appeared.clear();

    let mut failures = Vec::new();
    for step in &scenario.script {
        let before = world.observe(&machine);
        world.perform(&mut machine, &step.action);
        if step.settle {
            world.settle(&mut machine);
        }
        let after = world.observe(&machine);
        if step.expect_no_change {
            if let Some(difference) = first_difference(&before, &after) {
                failures.push(format!(
                    "{prefix} step {} {} is tagged expectNoChange but changed {difference}",
                    step.number, step.label
                ));
            }
        }
        if let Some(checkpoint) = &step.expect {
            failures.extend(
                compare(checkpoint, &after, &format!("step {} expect", step.number))
                    .into_iter()
                    .map(|failure| format!("{prefix} {failure}")),
            );
        }
    }
    let last = world.observe(&machine);
    failures.extend(
        compare(&scenario.expect, &last, "expect")
            .into_iter()
            .map(|failure| format!("{prefix} {failure}")),
    );
    failures
}
