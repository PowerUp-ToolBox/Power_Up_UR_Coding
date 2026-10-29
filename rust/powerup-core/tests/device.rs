//! Plays the `Tests/Fixtures/device/` tables (spec #97, slice 2.2) against
//! the core: the same files `DeviceFixtureTests` plays against the Swift app.

mod support;

use std::collections::BTreeSet;

use powerup_core::hold::HoldState;
use powerup_core::profile::{dualsense_profile, ControlKind, DeviceProfile, DUALSENSE_CONTROL_IDS};
use powerup_core::slots::select_active_controller;
use serde_json::Value;
use support::{
    action_from_descriptor, case_table, controller_descriptor, controller_from, effect_descriptor,
    phase_from,
};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

#[test]
fn control_kind_cases() {
    let file = "control-kind.json";
    for case in case_table("device", file).cases {
        let name = case
            .input
            .as_str()
            .unwrap_or_else(|| panic!("{file} case {:?}: input must be a string", case.name));
        let kind = ControlKind::from_wire(name);
        let actual = kind.map_or(Value::Null, |kind| Value::from(kind.wire_name()));
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
        // Through serde too, as a profile file is read and written back.
        let read = serde_json::from_value::<ControlKind>(case.input.clone()).ok();
        assert_eq!(read, kind, "{file} case {:?}: serde read", case.name);
        if let Some(kind) = read {
            assert_eq!(serde_json::to_value(kind).unwrap(), actual);
        }
    }
}

#[test]
fn profile_decode_cases() {
    let file = "profile-decode.json";
    for case in case_table("device", file).cases {
        let actual = serde_json::from_value::<DeviceProfile>(case.input.clone())
            .map_or(Value::Null, |profile| {
                serde_json::to_value(profile).unwrap()
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
fn dualsense_profile_case() {
    let file = "dualsense-profile.json";
    for case in case_table("device", file).cases {
        let actual = serde_json::to_value(dualsense_profile()).unwrap();
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
        let ids: Vec<&str> = case.expected["controls"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|control| control["id"].as_str())
            .collect();
        assert_eq!(ids, DUALSENSE_CONTROL_IDS, "{file}: control order");
    }
}

#[test]
fn slot_selection_cases() {
    let file = "slot-selection.json";
    for case in case_table("device", file).cases {
        let connected: Vec<_> = case.input["mostRecentlyConnectedFirst"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {:?}: no controller list", case.name))
            .iter()
            .map(controller_from)
            .collect();
        let pinned = match &case.input["pinnedID"] {
            Value::Null => None,
            Value::String(id) => Some(id.as_str()),
            other => panic!("{file} case {:?}: pinnedID {other}", case.name),
        };
        let actual =
            select_active_controller(&connected, pinned).map_or(Value::Null, controller_descriptor);
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

/// One state per case, starting idle and passed from step to step, as the
/// Swift adapter keeps it between presses.
#[test]
fn hold_rule_cases() {
    let file = "hold-rule.json";
    let mut seen = BTreeSet::new();
    for case in case_table("device", file).cases {
        let steps = case.input["steps"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {:?}: no steps", case.name));
        let mut state = HoldState::default();
        let mut effects = Vec::new();
        for step in steps {
            let next = if step["releaseAll"] == true {
                state.release_all()
            } else {
                let control = step["control"]
                    .as_str()
                    .unwrap_or_else(|| panic!("{file} case {:?}: bad step {step}", case.name));
                let toggle = step["toggleCaptureActive"]
                    .as_bool()
                    .unwrap_or_else(|| panic!("{file} case {:?}: bad step {step}", case.name));
                state.step(
                    &action_from_descriptor(&step["action"]),
                    control,
                    phase_from(&step["phase"]),
                    toggle,
                )
            };
            seen.insert(next.effect.name());
            effects.push(effect_descriptor(&next.effect));
            state = next.state;
        }
        let actual = serde_json::json!({"effects": effects, "owner": state.owner});
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
    // The table speaks the whole vocabulary, so every Rust name is checked
    // against a value the Swift app produced.
    assert_eq!(
        seen,
        BTreeSet::from([
            "beginCapture",
            "cancelCapture",
            "deliver",
            "endCapture",
            "ignore"
        ])
    );
}
