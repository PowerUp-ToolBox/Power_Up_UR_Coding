//! Plays the `Tests/Fixtures/mapping/` tables (spec #97, slice 2.2) against
//! the core: the same files `MappingFixtureTests` plays against the Swift app.

mod support;

use std::collections::BTreeSet;

use powerup_core::action::{Action, WIRE_NAMES};
use powerup_core::intent::intent_for;
use serde_json::Value;
use support::{
    action_descriptor, action_from_descriptor, case_table, intent_descriptor, phase_from,
};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

#[test]
fn action_shape_matches_swift_bytes() {
    let file = "action-shape.json";
    for case in case_table("mapping", file).cases {
        let action = action_from_descriptor(&case.input);
        let expected = case
            .expected
            .as_str()
            .unwrap_or_else(|| panic!("{file} case {:?}: expected must be a string", case.name));
        let actual = action.to_wire_json().unwrap();
        assert_eq!(
            actual,
            expected,
            "{}",
            fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &Value::from(actual.clone())
            )
        );
        let read_back: Action = serde_json::from_str(expected).unwrap();
        assert_eq!(read_back, action, "{file} case {:?}: read back", case.name);
    }
}

#[test]
fn action_decode_cases() {
    let file = "action-decode.json";
    for case in case_table("mapping", file).cases {
        let actual = Action::from_wire(&case.input)
            .map(|action| action_descriptor(&action))
            .unwrap_or(Value::Null);
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn intent_for_action_cases() {
    let file = "intent-for-action.json";
    let mut covered = BTreeSet::new();
    for case in case_table("mapping", file).cases {
        let action = action_from_descriptor(&case.input["action"]);
        let phase = phase_from(&case.input["phase"]);
        covered.insert((action.wire_name(), case.input["phase"].to_string()));
        let actual = intent_for(&action, phase)
            .map(|intent| intent_descriptor(&intent))
            .unwrap_or(Value::Null);
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
    assert_eq!(
        covered.len(),
        WIRE_NAMES.len() * 2,
        "{file}: every action meets both phases"
    );
}

#[test]
fn is_hold_cases() {
    let file = "is-hold.json";
    let mut covered = BTreeSet::new();
    for case in case_table("mapping", file).cases {
        let action = action_from_descriptor(&case.input);
        covered.insert(action.wire_name());
        let actual = Value::Bool(action.is_hold());
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
    assert_eq!(
        covered,
        WIRE_NAMES.into_iter().collect(),
        "{file}: one row per action"
    );
}
