//! Plays `Tests/Fixtures/hooks/` (spec #100, slice 2.5) against the core:
//! the tables `HookFixtureTests` plays through the Swift installer. Only
//! fixture text is read; no settings file is touched.
//!
//! A `write` case's file is what the macOS app writes after formatting the
//! core's JSON with Foundation's `JSONSerialization` (its collation orders
//! the keys and it spells the numbers), which the Swift runner compares
//! byte for byte. Here the core's JSON is compared with that file as JSON:
//! numbers by value, members in any order, and every string and key read
//! as Foundation reads it back (one leading U+FEFF dropped).

mod support;

use powerup_core::hooks::{
    hook_command, hook_script_body, install_edit, install_state, is_installed, uninstall_edit,
    SettingsEdit, SettingsRefusal,
};
use serde_json::{json, Value};
use support::{case_table, line_input_bytes, parse_unbounded, same_json_by_number_value};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

/// A file input: `null` is no file.
fn file_input(input: &Value) -> Option<Vec<u8>> {
    (!input.is_null()).then(|| line_input_bytes(input))
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

/// The script on disk: a file input, or the body for `scriptFor`.
fn script_input(input: &Value) -> Option<Vec<u8>> {
    let body = |spec: &Value| {
        hook_script_body(integer(&spec["port"]), string(&spec["token"])).into_bytes()
    };
    if let Some(spec) = input.get("scriptFor") {
        return Some(body(spec));
    }
    if let Some(spec) = input.get("scriptForWithoutTrailingNewline") {
        let mut bytes = body(spec);
        bytes.pop();
        return Some(bytes);
    }
    file_input(input)
}

/// Foundation drops one leading U+FEFF from every string and key it reads.
fn read_back_as_foundation(value: Value) -> Value {
    fn strip(text: String) -> String {
        match text.strip_prefix('\u{FEFF}') {
            Some(rest) => rest.to_owned(),
            None => text,
        }
    }
    match value {
        Value::String(text) => Value::String(strip(text)),
        Value::Array(items) => {
            Value::Array(items.into_iter().map(read_back_as_foundation).collect())
        }
        Value::Object(members) => Value::Object(
            members
                .into_iter()
                .map(|(key, value)| (strip(key), read_back_as_foundation(value)))
                .collect(),
        ),
        other => other,
    }
}

fn refusal_descriptor(refusal: &SettingsRefusal) -> Value {
    match refusal {
        SettingsRefusal::InvalidJson => json!({"outcome": "refused", "refusal": "invalidJSON"}),
        SettingsRefusal::HooksNotAnObject => {
            json!({"outcome": "refused", "refusal": "hooksNotAnObject"})
        }
        SettingsRefusal::EventNotAnArray { event } => {
            json!({"outcome": "refused", "refusal": "eventNotAnArray", "event": event})
        }
    }
}

fn play_edit_table(file: &str, edit: fn(Option<&[u8]>, &str) -> SettingsEdit) {
    for case in case_table("hooks", file).cases {
        let settings = file_input(&case.input["settings"]);
        let script_path = string(&case.input["scriptPath"]);
        let outcome = edit(settings.as_deref(), script_path);
        let failure = |actual: &Value| fail(file, &case.name, &case.reason, &case.expected, actual);
        match outcome {
            SettingsEdit::Write { json } => {
                let lines = case.expected["file"].as_array().unwrap_or_else(|| {
                    panic!("{}", failure(&json!({"outcome": "write", "json": json})))
                });
                assert_eq!(
                    case.expected["outcome"],
                    "write",
                    "{}",
                    failure(&json!(json))
                );
                let text = lines.iter().map(string).collect::<Vec<_>>().join("\n");
                let expected = parse_unbounded(&text);
                let actual = read_back_as_foundation(parse_unbounded(&json));
                assert!(
                    same_json_by_number_value(&actual, &expected),
                    "{}",
                    failure(&json!(json))
                );
            }
            SettingsEdit::Unchanged => {
                let actual = json!({"outcome": "unchanged"});
                assert_eq!(actual, case.expected, "{}", failure(&actual));
            }
            SettingsEdit::Refused(refusal) => {
                let actual = refusal_descriptor(&refusal);
                assert_eq!(actual, case.expected, "{}", failure(&actual));
            }
        }
    }
}

fn install(settings: Option<&[u8]>, script_path: &str) -> SettingsEdit {
    install_edit(settings, script_path).unwrap_or_else(|e| panic!("the core failed: {e}"))
}

fn uninstall(settings: Option<&[u8]>, script_path: &str) -> SettingsEdit {
    uninstall_edit(settings, script_path).unwrap_or_else(|e| panic!("the core failed: {e}"))
}

#[test]
fn hook_command_cases() {
    let file = "command.json";
    for case in case_table("hooks", file).cases {
        let actual = Value::String(hook_command(case.input.as_str().unwrap()));
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn hook_script_cases() {
    let file = "script.json";
    for case in case_table("hooks", file).cases {
        let body = hook_script_body(
            integer(&case.input["port"]),
            case.input["token"].as_str().unwrap(),
        );
        let actual = json!(body.split('\n').collect::<Vec<_>>());
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn install_cases() {
    play_edit_table("install.json", install);
}

#[test]
fn uninstall_cases() {
    play_edit_table("uninstall.json", uninstall);
}

#[test]
fn install_state_cases() {
    let file = "install-state.json";
    for case in case_table("hooks", file).cases {
        let input = &case.input;
        let settings = file_input(&input["settings"]);
        let script = script_input(&input["scriptOnDisk"]);
        let script_path = input["scriptPath"].as_str().unwrap();
        let state = install_state(
            settings.as_deref(),
            script_path,
            script.as_deref(),
            integer(&input["port"]),
            input["token"].as_str().unwrap(),
        );
        let actual = json!({
            "installState": state.name(),
            "isInstalled": is_installed(settings.as_deref(), script_path),
        });
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

/// The five-event rule of #158: whichever event an install lacks, the state
/// never reads as installed (outOfDate, or notInstalled without Stop).
#[test]
fn a_missing_event_never_reads_as_installed() {
    let file = "install-state.json";
    let table = case_table("hooks", file);
    for event in powerup_core::hooks::HOOK_EVENTS {
        let name = format!("{event} missing");
        let case = table
            .cases
            .iter()
            .find(|case| case.name == name)
            .unwrap_or_else(|| panic!("{file} has no case {name:?}"));
        assert_ne!(case.expected["installState"], "installed", "{name}");
    }
}
