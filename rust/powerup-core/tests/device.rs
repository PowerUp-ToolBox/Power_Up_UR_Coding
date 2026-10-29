//! Plays the `Tests/Fixtures/device/` tables (spec #97, slice 2.2) against
//! the core: the same files `DeviceFixtureTests` plays against the Swift app.

mod support;

use powerup_core::profile::{dualsense_profile, ControlKind, DeviceProfile, DUALSENSE_CONTROL_IDS};
use serde_json::Value;
use support::case_table;

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
