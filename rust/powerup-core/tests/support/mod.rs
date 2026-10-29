//! Loader for the shared fixtures in `Tests/Fixtures/` (stage 2.1, #140):
//! the same files the Swift suites run, read from the repository root so the
//! two implementations can never drift onto separate copies. The formats are
//! described in `Tests/Fixtures/README.md`. The top-level keys match the Swift
//! loaders (`SessionScenario.swift`, `TextSafetyFixtures`) and the header
//! checks are slightly stricter, so a file that loads here loads there.

// Each test binary uses part of this module. And this is test support, not
// library code: a broken fixture should stop the test with the file named,
// which is what expect does.
#![allow(dead_code, clippy::expect_used)]

use std::fs;
use std::path::{Path, PathBuf};

use powerup_core::action::Action;
use powerup_core::harness::acp::adapter::{AcpAdapterEffect, AcpSnapshot};
use powerup_core::harness::claude::adapter::{ClaudeAdapterEffect, ClaudeSnapshot};
use powerup_core::harness::claude::event::ClaudeEvent;
use powerup_core::harness::{HarnessEvent, HarnessState};
use powerup_core::hold::HoldEffect;
use powerup_core::intent::{ControlPhase, Intent};
use powerup_core::mapping::{default_device_mappings, DeviceMappings};
use powerup_core::slots::ConnectedController;
use serde::Deserialize;
use serde_json::Value;

/// `Tests/Fixtures/`, found from this crate's manifest (`rust/powerup-core`).
pub fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/Fixtures")
        .canonicalize()
        .expect("Tests/Fixtures must exist next to rust/")
}

/// Every `.json` file under `Tests/Fixtures/<area>` (or the whole directory
/// for `area == ""`), sorted for stable test output.
pub fn json_files(area: &str) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let entries =
            fs::read_dir(dir).unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()));
        for entry in entries {
            let path = entry.expect("directory entry").path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.extension().is_some_and(|ext| ext == "json") {
                out.push(path);
            }
        }
    }
    let mut files = Vec::new();
    walk(&fixtures_dir().join(area), &mut files);
    files.sort();
    files
}

/// A session scenario (`session/`, format 1). The script and expectations
/// stay JSON until a core slice plays them.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionScenario {
    pub format_version: u32,
    pub name: String,
    pub description: String,
    pub reason: String,
    pub source: String,
    pub verified_by: Vec<String>,
    pub config: Value,
    pub script: Vec<Value>,
    pub expect: Value,
}

/// A case table (`text-safety/`, `status/`, `mapping/`, `device/`, `harness/`,
/// `config/`, `transcript/`, `hooks/`, `speech/`, `protocol/`).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CaseTable {
    pub description: String,
    pub function: String,
    pub verified_by: String,
    #[serde(default)]
    pub captured_against: Option<String>,
    pub cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    pub name: String,
    pub input: Value,
    pub expected: Value,
    pub reason: String,
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// Loads and checks one session scenario; panics naming the file on any
/// problem.
pub fn load_session(path: &Path) -> SessionScenario {
    let scenario: SessionScenario =
        serde_json::from_str(&read(path)).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let file = path.display();
    assert_eq!(
        scenario.format_version, 1,
        "{file}: unsupported formatVersion"
    );
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    assert_eq!(scenario.name, stem, "{file}: name must match the file name");
    for (field, value) in [
        ("description", &scenario.description),
        ("reason", &scenario.reason),
        ("source", &scenario.source),
    ] {
        assert!(!value.trim().is_empty(), "{file}: empty {field}");
    }
    assert!(!scenario.verified_by.is_empty(), "{file}: empty verifiedBy");
    assert!(!scenario.script.is_empty(), "{file}: empty script");
    scenario
}

/// Loads and checks one case table; panics naming the file and case on any
/// problem.
pub fn load_case_table(path: &Path) -> CaseTable {
    let table: CaseTable =
        serde_json::from_str(&read(path)).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let file = path.display();
    for (field, value) in [
        ("description", &table.description),
        ("function", &table.function),
        ("verifiedBy", &table.verified_by),
    ] {
        assert!(!value.trim().is_empty(), "{file}: empty {field}");
    }
    assert!(!table.cases.is_empty(), "{file}: no cases");
    let mut names = std::collections::HashSet::new();
    for case in &table.cases {
        assert!(
            !case.name.trim().is_empty(),
            "{file}: a case has a blank name"
        );
        assert!(
            names.insert(case.name.as_str()),
            "{file}: duplicate case {:?}",
            case.name
        );
        assert!(
            !case.reason.trim().is_empty(),
            "{file}: case {:?} has no reason",
            case.name
        );
    }
    table
}

// Value descriptors (`Tests/Fixtures/README.md`, `mapping/`). An unknown name
// panics with the descriptor, so a fixture typo never reads as a real value.

/// `{"case": <name>}`, plus `"prompt"` for sendPrompt.
pub fn action_from_descriptor(descriptor: &Value) -> Action {
    let name = descriptor["case"]
        .as_str()
        .unwrap_or_else(|| panic!("not an action descriptor: {descriptor}"));
    if name == "sendPrompt" {
        let prompt = descriptor["prompt"]
            .as_str()
            .unwrap_or_else(|| panic!("sendPrompt descriptor without a prompt: {descriptor}"));
        return Action::SendPrompt(prompt.to_owned());
    }
    Action::from_wire(&serde_json::json!({ name: {} }))
        .unwrap_or_else(|| panic!("unknown action case in {descriptor}"))
}

pub fn action_descriptor(action: &Action) -> Value {
    match action {
        Action::SendPrompt(prompt) => serde_json::json!({"case": "sendPrompt", "prompt": prompt}),
        other => serde_json::json!({"case": other.wire_name()}),
    }
}

/// `{"intent": <name>}`, plus `"mode"` for beginVoiceCapture and `"prompt"`
/// for sendPrompt.
pub fn intent_descriptor(intent: &Intent) -> Value {
    match intent {
        Intent::BeginVoiceCapture(mode) => {
            serde_json::json!({"intent": intent.name(), "mode": mode.name()})
        }
        Intent::SendPrompt(prompt) => {
            serde_json::json!({"intent": intent.name(), "prompt": prompt})
        }
        other => serde_json::json!({"intent": other.name()}),
    }
}

pub fn phase_from(name: &Value) -> ControlPhase {
    match name.as_str() {
        Some("began") => ControlPhase::Began,
        Some("ended") => ControlPhase::Ended,
        _ => panic!("unknown phase {name}"),
    }
}

/// `{profileID: {controlID: <action descriptor>}}`, or `"defaults"` for the
/// shipped default mappings.
pub fn mappings_from_descriptors(descriptor: &Value) -> DeviceMappings {
    if descriptor == "defaults" {
        return default_device_mappings();
    }
    let profiles = descriptor
        .as_object()
        .unwrap_or_else(|| panic!("not a mappings descriptor: {descriptor}"));
    profiles
        .iter()
        .map(|(profile_id, mapping)| {
            let controls = mapping
                .as_object()
                .unwrap_or_else(|| panic!("not a profile mapping: {mapping}"));
            let mapping = controls
                .iter()
                .map(|(control_id, action)| (control_id.clone(), action_from_descriptor(action)))
                .collect();
            (profile_id.clone(), mapping)
        })
        .collect()
}

pub fn mappings_descriptor(mappings: &DeviceMappings) -> Value {
    mappings
        .iter()
        .map(|(profile_id, mapping)| {
            let controls = mapping
                .iter()
                .map(|(control_id, action)| (control_id.clone(), action_descriptor(action)))
                .collect::<serde_json::Map<_, _>>();
            (profile_id.clone(), Value::Object(controls))
        })
        .collect::<serde_json::Map<_, _>>()
        .into()
}

/// `{"effect": <name>}`, plus `"mode"` for beginCapture and `"intent"` (an
/// intent descriptor) for deliver.
pub fn effect_descriptor(effect: &HoldEffect) -> Value {
    match effect {
        HoldEffect::BeginCapture(mode) => {
            serde_json::json!({"effect": effect.name(), "mode": mode.name()})
        }
        HoldEffect::Deliver(intent) => {
            serde_json::json!({"effect": effect.name(), "intent": intent_descriptor(intent)})
        }
        other => serde_json::json!({"effect": other.name()}),
    }
}

/// `{"id", "profileID", "displayName"}`, every field a string.
pub fn controller_from(descriptor: &Value) -> ConnectedController {
    let field = |key: &str| {
        descriptor[key]
            .as_str()
            .unwrap_or_else(|| panic!("controller descriptor without a string {key}: {descriptor}"))
            .to_owned()
    };
    ConnectedController {
        id: field("id"),
        profile_id: field("profileID"),
        display_name: field("displayName"),
    }
}

pub fn controller_descriptor(controller: &ConnectedController) -> Value {
    serde_json::json!({
        "id": controller.id,
        "profileID": controller.profile_id,
        "displayName": controller.display_name,
    })
}

// Value descriptors (`Tests/Fixtures/README.md`, `harness/`).

/// A number as Swift's JSONEncoder writes it: an integral double inside
/// Double's exact range is an integer, so a cost of 1.0 equals a table's 1.
pub fn number_value(number: f64) -> Value {
    if number.is_finite() && number.fract() == 0.0 && number.abs() < 9_007_199_254_740_992.0 {
        // Exact: integral and below 2^53.
        #[allow(clippy::cast_possible_truncation)]
        return Value::from(number as i64);
    }
    serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number)
}

/// `{"event": <Swift case name>}` plus Swift's field names.
pub fn claude_event_descriptor(event: &ClaudeEvent) -> Value {
    match event {
        ClaudeEvent::Ready { session_id, model } => {
            serde_json::json!({"event": "ready", "sessionID": session_id, "model": model})
        }
        ClaudeEvent::TextDelta(text) => serde_json::json!({"event": "textDelta", "text": text}),
        ClaudeEvent::AssistantMessage(text) => {
            serde_json::json!({"event": "assistantMessage", "text": text})
        }
        ClaudeEvent::ToolUse { name, detail } => {
            serde_json::json!({"event": "toolUse", "name": name, "detail": detail})
        }
        ClaudeEvent::TurnCompleted {
            result_text,
            cost_usd,
            is_error,
            subtype,
        } => serde_json::json!({
            "event": "turnCompleted",
            "resultText": result_text,
            "costUSD": cost_usd.map_or(Value::Null, number_value),
            "isError": is_error,
            "subtype": subtype,
        }),
        ClaudeEvent::ControlResult {
            action,
            ok,
            detail,
            value,
        } => serde_json::json!({
            "event": "controlResult", "action": action, "ok": ok, "detail": detail, "value": value,
        }),
        ClaudeEvent::ProcessError(message) => {
            serde_json::json!({"event": "processError", "message": message})
        }
        ClaudeEvent::Terminated { exit_code } => {
            serde_json::json!({"event": "terminated", "exitCode": exit_code})
        }
    }
}

/// A harness event as session scenarios write it: tagged by `type`, with
/// Swift's field names, and every optional field written (`null` when
/// absent).
pub fn harness_event_descriptor(event: &HarnessEvent) -> Value {
    let optional_number = |number: &Option<f64>| number.map_or(Value::Null, number_value);
    match event {
        HarnessEvent::SessionReady { session_id, model } => {
            serde_json::json!({"type": "sessionReady", "sessionID": session_id, "model": model})
        }
        HarnessEvent::ReplyDelta(text) => serde_json::json!({"type": "replyDelta", "text": text}),
        HarnessEvent::Reply(text) => serde_json::json!({"type": "reply", "text": text}),
        HarnessEvent::ToolUse { name, detail } => {
            serde_json::json!({"type": "toolUse", "name": name, "detail": detail})
        }
        HarnessEvent::TurnCompleted {
            result_text,
            cost_usd,
            is_error,
            detail,
        } => serde_json::json!({
            "type": "turnCompleted",
            "resultText": result_text,
            "costUSD": optional_number(cost_usd),
            "isError": is_error,
            "detail": detail,
        }),
        HarnessEvent::ControlResult {
            action,
            ok,
            detail,
            value,
        } => serde_json::json!({
            "type": "controlResult", "action": action, "ok": ok, "detail": detail, "value": value,
        }),
        HarnessEvent::PermissionRequest {
            id,
            name,
            kind,
            detail,
        } => serde_json::json!({
            "type": "permissionRequest", "id": id, "name": name, "kind": kind, "detail": detail,
        }),
        HarnessEvent::Notification(message) => {
            serde_json::json!({"type": "notification", "message": message})
        }
        HarnessEvent::RuntimeError(message) => {
            serde_json::json!({"type": "runtimeError", "message": message})
        }
        HarnessEvent::Ended { exit_code } => {
            serde_json::json!({"type": "ended", "exitCode": exit_code})
        }
    }
}

pub fn harness_state_name(state: HarnessState) -> &'static str {
    match state {
        HarnessState::Stopped => "stopped",
        HarnessState::Starting => "starting",
        HarnessState::Ready => "ready",
        HarnessState::Working => "working",
    }
}

/// `{state, sessionID, modelName, totalCostUSD}`.
pub fn claude_snapshot_fields(snapshot: &ClaudeSnapshot) -> serde_json::Map<String, Value> {
    let mut fields = serde_json::Map::new();
    fields.insert("state".into(), harness_state_name(snapshot.state).into());
    fields.insert("sessionID".into(), snapshot.session_id.clone().into());
    fields.insert("modelName".into(), snapshot.model_name.clone().into());
    fields.insert("totalCostUSD".into(), number_value(snapshot.total_cost_usd));
    fields
}

/// `{"effect": <name>}` plus the effect's fields; a written line is the
/// JSON object it holds, and must be exactly one line.
pub fn adapter_effect_descriptor(effect: &ClaudeAdapterEffect) -> Value {
    match effect {
        ClaudeAdapterEffect::Publish(snapshot) => {
            let mut fields = claude_snapshot_fields(snapshot);
            fields.insert("effect".into(), "publish".into());
            Value::Object(fields)
        }
        ClaudeAdapterEffect::ResolveBinary {
            generation,
            binary_path_override,
        } => serde_json::json!({
            "effect": "resolveBinary", "generation": generation,
            "binaryPathOverride": binary_path_override,
        }),
        ClaudeAdapterEffect::Spawn {
            generation,
            executable,
            arguments,
            project_dir,
        } => serde_json::json!({
            "effect": "spawn", "generation": generation, "executable": executable,
            "arguments": arguments, "projectDir": project_dir,
        }),
        ClaudeAdapterEffect::WriteStdin(line) => {
            serde_json::json!({"effect": "writeStdin", "line": stdin_line_object(line)})
        }
        ClaudeAdapterEffect::CloseStdin => serde_json::json!({"effect": "closeStdin"}),
        ClaudeAdapterEffect::TerminateAfterGrace { seconds } => {
            serde_json::json!({"effect": "terminateAfterGrace", "seconds": number_value(*seconds)})
        }
        ClaudeAdapterEffect::Emit(event) => {
            serde_json::json!({"effect": "emit", "event": harness_event_descriptor(event)})
        }
    }
}

/// The JSON object one written stdin line holds; the line must be UTF-8
/// and end with its only newline.
pub fn stdin_line_object(line: &[u8]) -> Value {
    let text =
        std::str::from_utf8(line).unwrap_or_else(|e| panic!("a stdin line is not UTF-8: {e}"));
    assert!(
        text.ends_with('\n') && text.matches('\n').count() == 1,
        "a stdin line is not one line: {text:?}"
    );
    serde_json::from_str(text).unwrap_or_else(|e| panic!("a stdin line is not JSON: {e}: {text:?}"))
}

/// `{state, sessionID, modelName, totalTokens}`.
pub fn acp_snapshot_fields(snapshot: &AcpSnapshot) -> serde_json::Map<String, Value> {
    let mut fields = serde_json::Map::new();
    fields.insert("state".into(), harness_state_name(snapshot.state).into());
    fields.insert("sessionID".into(), snapshot.session_id.clone().into());
    fields.insert("modelName".into(), snapshot.model_name.clone().into());
    fields.insert("totalTokens".into(), snapshot.total_tokens.into());
    fields
}

/// An acp effect (`Tests/Fixtures/README.md`, the ACP adapter): `{"effect":
/// <name>}` plus the effect's fields; a written line is the JSON object it
/// holds.
pub fn acp_effect_descriptor(effect: &AcpAdapterEffect) -> Value {
    match effect {
        AcpAdapterEffect::Publish(snapshot) => {
            let mut fields = acp_snapshot_fields(snapshot);
            fields.insert("effect".into(), "publish".into());
            Value::Object(fields)
        }
        AcpAdapterEffect::Spawn {
            generation,
            executable,
            arguments,
            project_dir,
        } => serde_json::json!({
            "effect": "spawn", "generation": generation, "executable": executable,
            "arguments": arguments, "projectDir": project_dir,
        }),
        AcpAdapterEffect::WriteStdin(line) => {
            serde_json::json!({"effect": "writeStdin", "line": stdin_line_object(line)})
        }
        AcpAdapterEffect::CloseStdin => serde_json::json!({"effect": "closeStdin"}),
        AcpAdapterEffect::TerminateAfterGrace { seconds } => {
            serde_json::json!({"effect": "terminateAfterGrace", "seconds": number_value(*seconds)})
        }
        AcpAdapterEffect::ArmStartWatchdog {
            generation,
            seconds,
        } => serde_json::json!({
            "effect": "armStartWatchdog", "generation": generation, "seconds": number_value(*seconds),
        }),
        AcpAdapterEffect::Emit(event) => {
            serde_json::json!({"effect": "emit", "event": harness_event_descriptor(event)})
        }
    }
}

/// A line input: a string (the line as UTF-8), or `{"hex": "<bytes>"}`.
pub fn line_input_bytes(input: &Value) -> Vec<u8> {
    if let Some(text) = input.as_str() {
        return text.as_bytes().to_vec();
    }
    let hex = input["hex"]
        .as_str()
        .unwrap_or_else(|| panic!("not a line input: {input}"));
    assert!(
        hex.len().is_multiple_of(2),
        "odd hex in line input: {input}"
    );
    (0..hex.len())
        .step_by(2)
        .map(|at| {
            u8::from_str_radix(&hex[at..at + 2], 16)
                .unwrap_or_else(|e| panic!("bad hex in line input {input}: {e}"))
        })
        .collect()
}

/// The table at `Tests/Fixtures/<area>/<file>`.
pub fn case_table(area: &str, file: &str) -> CaseTable {
    load_case_table(&fixtures_dir().join(area).join(file))
}

/// JSON text parsed however deep it nests (a fixture may hold a value 512
/// containers deep, past serde_json's default limit of 128).
pub fn parse_unbounded(text: &str) -> Value {
    let mut deserializer = serde_json::Deserializer::from_str(text);
    deserializer.disable_recursion_limit();
    let value =
        Value::deserialize(&mut deserializer).unwrap_or_else(|e| panic!("not JSON ({e}): {text}"));
    deserializer
        .end()
        .unwrap_or_else(|e| panic!("trailing text ({e}): {text}"));
    value
}

/// Two JSON values with numbers compared by value, as the doubles they
/// read as (so `0.1` equals `0.10000000000000001` and `-0.0` equals `-0`),
/// object members by key and in any order. Iterative, for deep values.
pub fn same_json_by_number_value(left: &Value, right: &Value) -> bool {
    let mut pending = vec![(left, right)];
    while let Some((left, right)) = pending.pop() {
        match (left, right) {
            (Value::Number(a), Value::Number(b)) => {
                if a.as_f64() != b.as_f64() {
                    return false;
                }
            }
            (Value::Array(a), Value::Array(b)) => {
                if a.len() != b.len() {
                    return false;
                }
                pending.extend(a.iter().zip(b));
            }
            (Value::Object(a), Value::Object(b)) => {
                if a.len() != b.len() {
                    return false;
                }
                for (key, value) in a {
                    let Some(other) = b.get(key) else {
                        return false;
                    };
                    pending.push((value, other));
                }
            }
            (a, b) => {
                if a != b {
                    return false;
                }
            }
        }
    }
    true
}
