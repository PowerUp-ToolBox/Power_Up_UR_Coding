//! Plays the `Tests/Fixtures/status/` tables (spec #94; ported in slice
//! 2.3) against the core: the same files `StatusDerivationTests` plays
//! against the Swift app.

mod support;

use std::collections::BTreeMap;

use powerup_core::harness::HarnessState;
use powerup_core::status::{
    derived_is_working, derived_status, live_remote_turns, remote_turn_is_active,
    REMOTE_TURN_EXPIRY_SECONDS,
};
use serde_json::Value;
use support::case_table;

/// Any instant works; this is the scripted clock's start in the Swift
/// session runner.
const NOW: f64 = 800_000_000.0;

fn flag(input: &Value, key: &str) -> bool {
    input[key]
        .as_bool()
        .unwrap_or_else(|| panic!("{key} must be a bool in {input}"))
}

fn check(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> Option<String> {
    (expected != actual).then(|| {
        format!(
            "{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}"
        )
    })
}

#[test]
fn derivation_cases() {
    let file = "derivation.json";
    let failures: Vec<String> = case_table("status", file)
        .cases
        .iter()
        .filter_map(|case| {
            let input = &case.input;
            let status = derived_status(
                flag(input, "controllerConnected"),
                flag(input, "isPTTActive"),
                flag(input, "isSpeaking"),
                flag(input, "isWorking"),
            );
            check(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &status.name().into(),
            )
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn harness_state(name: &Value) -> HarnessState {
    match name.as_str() {
        Some("stopped") => HarnessState::Stopped,
        Some("starting") => HarnessState::Starting,
        Some("ready") => HarnessState::Ready,
        Some("working") => HarnessState::Working,
        _ => panic!("unknown harness state {name}"),
    }
}

#[test]
fn working_cases() {
    let file = "working.json";
    let failures: Vec<String> = case_table("status", file)
        .cases
        .iter()
        .filter_map(|case| {
            let input = &case.input;
            let working = derived_is_working(
                harness_state(&input["harnessState"]),
                flag(input, "isRemoteMode"),
                flag(input, "remoteTurnActive"),
            );
            check(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &working.into(),
            )
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn remote_turn_cases() {
    let file = "remote-turns.json";
    let failures: Vec<String> = case_table("status", file)
        .cases
        .iter()
        .filter_map(|case| {
            let input = &case.input;
            let ages = input["turnAgesSeconds"]
                .as_object()
                .unwrap_or_else(|| panic!("turnAgesSeconds must be an object in {input}"));
            let turns: BTreeMap<String, f64> = ages
                .iter()
                .map(|(id, age)| {
                    let age = age
                        .as_f64()
                        .unwrap_or_else(|| panic!("an age must be a number in {input}"));
                    (id.clone(), NOW - age)
                })
                .collect();
            let expiry = input["expirySeconds"]
                .as_f64()
                .unwrap_or_else(|| panic!("expirySeconds must be a number in {input}"));
            let focus = match &input["focus"] {
                Value::Null => None,
                Value::String(focus) => Some(focus.as_str()),
                other => panic!("focus must be a string or null, not {other}"),
            };
            let kept = live_remote_turns(&turns, NOW, expiry);
            let actual = serde_json::json!({
                "kept": kept.keys().collect::<Vec<_>>(),
                "active": remote_turn_is_active(&kept, focus),
            });
            check(file, &case.name, &case.reason, &case.expected, &actual)
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn the_remote_turn_expiry_is_fifteen_minutes() {
    assert_eq!(REMOTE_TURN_EXPIRY_SECONDS, 900.0);
}
