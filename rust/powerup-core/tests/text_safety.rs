//! Plays `Tests/Fixtures/text-safety/` (spec #93; ported in slice 2.5)
//! against the core: the tables `TextSafetyFixtureTests` and
//! `CmuxReportingFixtureTests` play through the Swift remote-control
//! service. Strings are compared exactly, scalar for scalar, and the
//! properties the Swift suites check beside the tables (segments join to
//! the flattened text and are never empty; a condensed line stays within
//! its limit) are checked on every case too.

mod support;

use powerup_core::text::grapheme_count;
use powerup_core::text_safety::{
    condense, escape_safe_segments, failure_message, flatten_line_breaks, parse_workspaces,
    strip_status_glyph, CmuxWorkspace, CommandResult,
};
use serde_json::{json, Value};
use support::case_table;

fn fail(
    file: &str,
    name: &str,
    reason: &str,
    input: &Value,
    expected: &Value,
    actual: &Value,
) -> String {
    format!(
        "{file} case {name:?} failed (guards: {reason})\n  input:    {input}\n  expected: {expected}\n  actual:   {actual}"
    )
}

fn string(value: &Value) -> &str {
    value
        .as_str()
        .unwrap_or_else(|| panic!("not a string: {value}"))
}

fn integer(value: &Value) -> i64 {
    value
        .as_i64()
        .unwrap_or_else(|| panic!("not an integer: {value}"))
}

fn flag(value: &Value) -> bool {
    value
        .as_bool()
        .unwrap_or_else(|| panic!("not a bool: {value}"))
}

/// Plays one table whose cases map an input to a JSON value.
fn play(file: &str, run: impl Fn(&Value) -> Value) {
    let table = case_table("text-safety", file);
    let failures: Vec<String> = table
        .cases
        .iter()
        .filter_map(|case| {
            let actual = run(&case.input);
            (actual != case.expected).then(|| {
                fail(
                    file,
                    &case.name,
                    &case.reason,
                    &case.input,
                    &case.expected,
                    &actual,
                )
            })
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn workspace_descriptor(row: &CmuxWorkspace) -> Value {
    json!({"ref": row.reference, "title": row.title, "selected": row.selected})
}

#[test]
fn line_break_cases() {
    play("line-breaks.json", |input| {
        json!(flatten_line_breaks(string(input)))
    });
}

#[test]
fn segmentation_cases() {
    play("segmentation.json", |input| {
        let text = string(input);
        let segments = escape_safe_segments(text);
        assert_eq!(segments.concat(), flatten_line_breaks(text), "{input}");
        assert!(
            segments.iter().all(|segment| !segment.is_empty()),
            "{input}"
        );
        json!(segments)
    });
}

#[test]
fn workspace_cases() {
    play("cmux-workspaces.json", |input| {
        Value::Array(
            parse_workspaces(string(input))
                .iter()
                .map(workspace_descriptor)
                .collect(),
        )
    });
}

#[test]
fn status_glyph_cases() {
    play("status-glyph.json", |input| {
        json!(strip_status_glyph(string(input)))
    });
}

#[test]
fn condense_cases() {
    play("condense.json", |input| {
        let limit = integer(&input["maxChars"]);
        let line = condense(string(&input["text"]), limit);
        if limit >= 2 {
            let count = grapheme_count(&line);
            assert!(i64::try_from(count).unwrap() <= limit, "{input}");
        }
        json!(line)
    });
}

#[test]
fn failure_message_cases() {
    play("failure-message.json", |input| {
        let result = CommandResult {
            status: integer(&input["status"]),
            standard_output: string(&input["standardOutput"]).to_owned(),
            standard_error: string(&input["standardError"]).to_owned(),
            timed_out: flag(&input["timedOut"]),
            spawn_failed: flag(&input["spawnFailed"]),
        };
        json!(failure_message(string(&input["action"]), &result))
    });
}
