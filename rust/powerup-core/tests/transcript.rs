//! Plays `Tests/Fixtures/transcript/` (spec #100, slice 2.5) against the
//! core: the tables `TranscriptFixtureTests` plays through the Swift store.

mod support;

use powerup_core::transcript::{
    decode_line, entry_line, file_name, load_tail, TranscriptEntry, TranscriptKind,
};
use serde_json::{json, Value};
use support::{case_table, line_input_bytes};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

fn entry_descriptor(entry: &TranscriptEntry) -> Value {
    json!({
        "id": entry.id,
        "kind": entry.kind.name(),
        "text": entry.text,
        "date": entry.date_seconds,
    })
}

fn entry_from(descriptor: &Value) -> TranscriptEntry {
    let field = |key: &str| {
        descriptor[key]
            .as_str()
            .unwrap_or_else(|| panic!("{key} must be a string: {descriptor}"))
            .to_owned()
    };
    TranscriptEntry {
        id: field("id"),
        kind: TranscriptKind::from_name(&field("kind"))
            .unwrap_or_else(|| panic!("not a transcript kind: {descriptor}")),
        text: field("text"),
        date_seconds: descriptor["date"]
            .as_f64()
            .unwrap_or_else(|| panic!("date must be a number: {descriptor}")),
    }
}

/// Dates compare by value, so `0` and `0.0` are the same date.
fn same_entry(actual: &Value, expected: &Value) -> bool {
    match (actual, expected) {
        (Value::Null, Value::Null) => true,
        (Value::Object(_), Value::Object(_)) => {
            ["id", "kind", "text"]
                .iter()
                .all(|key| actual[key] == expected[key])
                && actual["date"].as_f64() == expected["date"].as_f64()
                && actual.as_object().map(|o| o.len()) == expected.as_object().map(|o| o.len())
        }
        _ => false,
    }
}

#[test]
fn transcript_line_cases() {
    let file = "lines.json";
    for case in case_table("transcript", file).cases {
        let actual = decode_line(&line_input_bytes(&case.input))
            .as_ref()
            .map_or(Value::Null, entry_descriptor);
        assert!(
            same_entry(&actual, &case.expected),
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn transcript_encode_cases() {
    let file = "encode.json";
    for case in case_table("transcript", file).cases {
        let line = entry_line(&entry_from(&case.input)).unwrap();
        let actual = Value::String(line.strip_suffix('\n').unwrap().to_owned());
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn transcript_load_cases() {
    let file = "load.json";
    for case in case_table("transcript", file).cases {
        let bytes = line_input_bytes(&case.input["file"]);
        let max_entries = usize::try_from(case.input["maxEntries"].as_u64().unwrap()).unwrap();
        let load = load_tail(&bytes, max_entries);
        let actual = json!({
            "texts": load.entries.iter().map(|entry| entry.text.as_str()).collect::<Vec<_>>(),
            "rewrite": load.rewrite.is_some(),
        });
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn transcript_file_name_cases() {
    let file = "file-name.json";
    for case in case_table("transcript", file).cases {
        let actual = Value::String(file_name(case.input.as_str().unwrap()));
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}
