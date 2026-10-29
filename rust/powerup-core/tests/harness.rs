//! Plays the `Tests/Fixtures/harness/` tables (spec #98, slice 2.3) against
//! the core: the same files `HarnessFixtureTests` plays against the Swift
//! app.

mod support;

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
