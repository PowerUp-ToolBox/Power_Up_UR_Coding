//! Plays the `Tests/Fixtures/harness/` tables (spec #98, slice 2.3) against
//! the core: the same files `HarnessFixtureTests` plays against the Swift
//! app.

mod support;

use powerup_core::harness::claude::launch::launch_arguments;
use powerup_core::harness::claude::lines::LineBuffer;
use powerup_core::harness::claude::parse::events_from_line;
use powerup_core::harness::claude::stdin::{control_request_line, user_turn_line, ControlRequest};
use serde_json::Value;
use support::{case_table, claude_event_descriptor, line_input_bytes};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

#[test]
fn claude_stream_cases() {
    let file = "claude-stream.json";
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let line = line_input_bytes(&case.input);
        let actual = Value::Array(
            events_from_line(&line)
                .iter()
                .map(claude_event_descriptor)
                .collect(),
        );
        if actual != case.expected {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// The line one stdin call writes, or `None` when it writes nothing.
fn stdin_line(input: &Value) -> Option<Vec<u8>> {
    let field = |key: &str| input[key].as_str();
    let request_id = || {
        field("requestID").unwrap_or_else(|| panic!("a control request needs a requestID: {input}"))
    };
    let request = match field("call") {
        Some("send") => {
            return user_turn_line(field("text").unwrap_or_default())
                .unwrap_or_else(|e| panic!("{input}: {e}"))
        }
        Some("interrupt") => Some(ControlRequest::Interrupt),
        Some("setModel") => ControlRequest::set_model(field("model").unwrap_or_default()),
        Some("setPermissionMode") => {
            ControlRequest::set_permission_mode(field("mode").unwrap_or_default())
        }
        _ => panic!("unknown stdin call: {input}"),
    };
    request.map(|request| {
        control_request_line(request_id(), &request).unwrap_or_else(|e| panic!("{input}: {e}"))
    })
}

#[test]
fn claude_stdin_cases() {
    let file = "claude-stdin.json";
    for case in case_table("harness", file).cases {
        let actual = match stdin_line(&case.input) {
            Some(line) => {
                let text = String::from_utf8(line).unwrap();
                assert!(
                    text.ends_with('\n') && text.matches('\n').count() == 1,
                    "{file} case {:?}: not one line: {text:?}",
                    case.name
                );
                serde_json::from_str(&text).unwrap()
            }
            None => Value::Null,
        };
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

fn text_of(bytes: Vec<u8>) -> Value {
    Value::String(String::from_utf8(bytes).unwrap_or_else(|e| panic!("a line is not UTF-8: {e}")))
}

#[test]
fn claude_lines_cases() {
    let file = "claude-lines.json";
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let chunks = case.input["chunks"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {:?}: no chunks", case.name));
        let flush = case.input["flush"]
            .as_bool()
            .unwrap_or_else(|| panic!("{file} case {:?}: no flush", case.name));
        let mut buffer = LineBuffer::new();
        let lines: Vec<Value> = chunks
            .iter()
            .map(|chunk| {
                let finished = buffer.ingest(&line_input_bytes(chunk));
                Value::Array(finished.into_iter().map(text_of).collect())
            })
            .collect();
        let remainder = if flush {
            let remainder = buffer.flush().map_or(Value::Null, text_of);
            assert_eq!(
                buffer.flush(),
                None,
                "{file} case {:?}: a second flush gave bytes",
                case.name
            );
            remainder
        } else {
            Value::Null
        };
        let actual = serde_json::json!({"lines": lines, "remainder": remainder});
        if actual != case.expected {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn claude_launch_cases() {
    let file = "claude-launch.json";
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let field = |key: &str| {
            case.input[key]
                .as_str()
                .unwrap_or_else(|| panic!("{file} case {:?}: no string {key}", case.name))
        };
        let resume = &case.input["resumeSessionID"];
        assert!(
            resume.is_null() || resume.is_string(),
            "{file} case {:?}: resumeSessionID must be a string or null",
            case.name
        );
        let actual = Value::from(launch_arguments(
            field("model"),
            field("permissionMode"),
            field("effort"),
            resume.as_str(),
        ));
        if actual != case.expected {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
