//! Plays the `Tests/Fixtures/mapping/` tables (spec #97, slice 2.2) against
//! the core: the same files `MappingFixtureTests` plays against the Swift app.

mod support;

use std::collections::BTreeSet;

use powerup_core::action::{Action, WIRE_NAMES};
use powerup_core::intent::intent_for;
use powerup_core::mapping::{default_device_mappings, load_device_mappings, resolve_action};
use serde_json::{json, Value};
use support::{
    action_descriptor, action_from_descriptor, case_table, intent_descriptor, mappings_descriptor,
    mappings_from_descriptors, phase_from,
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

#[test]
fn default_mapping_case() {
    let file = "default-mapping.json";
    for case in case_table("mapping", file).cases {
        let actual = mappings_descriptor(&default_device_mappings());
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

#[test]
fn resolve_action_cases() {
    let file = "resolve-action.json";
    for case in case_table("mapping", file).cases {
        let mappings = mappings_from_descriptors(&case.input["deviceMappings"]);
        let text = |key: &str| {
            case.input[key]
                .as_str()
                .unwrap_or_else(|| panic!("{file} case {:?}: {key} must be a string", case.name))
                .to_owned()
        };
        let actual = action_descriptor(&resolve_action(
            &mappings,
            &text("profile"),
            &text("control"),
        ));
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

/// The core takes the config as text, as the app hands it over.
#[test]
fn config_load_cases() {
    let file = "config-load.json";
    for case in case_table("mapping", file).cases {
        let load = load_device_mappings(&case.input.to_string()).unwrap();
        let actual = json!({
            "deviceMappings": mappings_descriptor(&load.device_mappings),
            "backupBeforeSave": load.backup_before_save,
        });
        // "defaults" in the table is spelled out so the comparison is value
        // for value.
        let expected = json!({
            "deviceMappings": mappings_descriptor(&mappings_from_descriptors(
                &case.expected["deviceMappings"]
            )),
            "backupBeforeSave": case.expected["backupBeforeSave"],
        });
        assert_eq!(
            actual,
            expected,
            "{}",
            fail(file, &case.name, &case.reason, &expected, &actual)
        );
    }
}
