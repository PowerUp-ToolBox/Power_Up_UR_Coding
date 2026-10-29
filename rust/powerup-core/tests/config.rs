//! Plays `Tests/Fixtures/config/round-trip.json` (spec #100, slice 2.5)
//! against the core, the table `ConfigFixtureTests` plays against the Swift
//! app, and `mapping/config-load.json` through the whole config decoder.

mod support;

use powerup_core::config::{encode_config, load_config, ConfigLoad};
use serde_json::{json, Value};
use support::{case_table, line_input_bytes, mappings_descriptor, mappings_from_descriptors};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

/// Load, then save: the saved text compared line for line (so byte for
/// byte), and the backup decision.
#[test]
fn config_round_trip_cases() {
    let file = "round-trip.json";
    for case in case_table("config", file).cases {
        let bytes = line_input_bytes(&case.input);
        let actual = match load_config(&bytes) {
            ConfigLoad::Corrupt => json!({"saved": null, "backupBeforeSave": false}),
            ConfigLoad::Loaded {
                config,
                backup_before_save,
            } => {
                let text = encode_config(&config).unwrap();
                json!({
                    "saved": text.split('\n').collect::<Vec<_>>(),
                    "backupBeforeSave": backup_before_save,
                })
            }
        };
        assert_eq!(
            actual,
            case.expected,
            "{}",
            fail(file, &case.name, &case.reason, &case.expected, &actual)
        );
    }
}

/// The mapping subtree's own table, read through `config::load_config`
/// rather than `mapping::load_device_mappings`, so the JSONDecoder reading
/// in front of the mapping layer is checked against it too.
#[test]
fn config_load_cases_through_the_config_decoder() {
    let file = "config-load.json";
    for case in case_table("mapping", file).cases {
        let text = serde_json::to_string(&case.input).unwrap();
        let ConfigLoad::Loaded {
            config,
            backup_before_save,
        } = load_config(text.as_bytes())
        else {
            panic!("{file} case {:?}: the config did not load", case.name);
        };
        let actual = json!({
            "deviceMappings": mappings_descriptor(&config.device_mappings),
            "backupBeforeSave": backup_before_save,
        });
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
