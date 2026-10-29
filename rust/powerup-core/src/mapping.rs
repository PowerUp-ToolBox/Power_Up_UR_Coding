//! Mappings (ADR 0006, DESIGN v2.4 B and C): which action each control of
//! each device profile is bound to, and how `config.json`'s mapping subtree
//! loads. The stored shape is `{profile id: {control id: action}}`, keyed
//! objects all the way down.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::action::Action;
use crate::profile::{DUALSENSE_CONTROL_IDS, DUALSENSE_PROFILE_ID};
use crate::CoreError;

/// Control id → action, for one profile.
pub type DeviceMapping = BTreeMap<String, Action>;

/// Profile id → that profile's mapping.
pub type DeviceMappings = BTreeMap<String, DeviceMapping>;

/// The config key holding the mappings since ADR 0006.
pub const DEVICE_MAPPINGS_KEY: &str = "deviceMappings";

/// The pre-ADR-0006 key: one button-keyed mapping for the DualSense.
pub const LEGACY_MAPPING_KEY: &str = "mapping";

/// The action bound to (profile, control), or [`Action::None`] when either
/// has no binding. Ids are compared exactly. This is the one resolution
/// point every input source routes through (DESIGN v2.4 B).
pub fn resolve_action(mappings: &DeviceMappings, profile_id: &str, control_id: &str) -> Action {
    mappings
        .get(profile_id)
        .and_then(|mapping| mapping.get(control_id))
        .cloned()
        .unwrap_or(Action::None)
}

/// The DualSense layout a fresh config ships with (the v1.3 layout, HK-007).
/// Every control is listed, the PS button as an explicit none.
pub fn default_mapping() -> DeviceMapping {
    let prompt = |text: &str| Action::SendPrompt(text.to_owned());
    [
        ("cross", Action::Approve),
        ("circle", Action::Interrupt),
        ("square", prompt("Continue")),
        ("triangle", Action::StopSpeaking),
        ("dpadUp", prompt("Run the tests and report the results")),
        ("dpadDown", prompt("Explain what you just did, briefly")),
        ("dpadLeft", prompt("Undo the last change you made")),
        (
            "dpadRight",
            prompt("Commit the current changes with a good message"),
        ),
        ("l1", Action::SendDraft),
        ("r1", Action::ToggleTts),
        ("l2", Action::PushToTalkDraft),
        ("r2", Action::PushToTalk),
        ("l3", Action::CycleModel),
        ("r3", Action::CycleEffort),
        ("create", Action::ShowWindow),
        ("options", Action::NewSession),
        ("touchpad", Action::CyclePermissionMode),
        ("ps", Action::None),
    ]
    .into_iter()
    .map(|(control_id, action)| (control_id.to_owned(), action))
    .collect()
}

/// The stored default: the DualSense profile carrying [`default_mapping`].
pub fn default_device_mappings() -> DeviceMappings {
    BTreeMap::from([(DUALSENSE_PROFILE_ID.to_owned(), default_mapping())])
}

/// What loading a config's mapping subtree gives: the mappings to use, and
/// whether the file must be copied to `config.pre-profiles.json` before the
/// next save rewrites it (the copy itself is the caller's: a file
/// operation, done once, never overwriting an earlier copy).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MappingLoad {
    pub device_mappings: DeviceMappings,
    pub backup_before_save: bool,
}

/// The deepest nesting of arrays and objects config.json text may have:
/// exactly what Foundation's JSONDecoder reads (it rejects 513 levels), so
/// every file the Swift app can decode loads here too. serde_json's own limit
/// of 128 would reject files the app has always read and silently reset
/// their bindings; no limit at all would let a hostile file overflow the
/// stack, which contain() cannot catch.
pub const MAX_CONFIG_DEPTH: usize = 512;

/// [`load_device_mappings_from`] on config.json text. Fails only when the
/// text is not JSON, not a JSON object, or nested deeper than
/// [`MAX_CONFIG_DEPTH`]; the caller then treats the file as unreadable.
pub fn load_device_mappings(config_json: &str) -> Result<MappingLoad, CoreError> {
    let value = parse_config(config_json).map_err(|message| CoreError::Failed {
        message: format!("config is not JSON: {message}"),
    })?;
    match value {
        Value::Object(config) => Ok(load_device_mappings_from(&config)),
        _ => Err(CoreError::Failed {
            message: "config is not a JSON object".to_owned(),
        }),
    }
}

/// Parses config.json text with serde_json's recursion limit lifted, after
/// checking the nesting against [`MAX_CONFIG_DEPTH`] without recursing.
fn parse_config(text: &str) -> Result<Value, String> {
    let depth = max_nesting_depth(text);
    if depth > MAX_CONFIG_DEPTH {
        return Err(format!(
            "nested {depth} levels deep, more than {MAX_CONFIG_DEPTH}"
        ));
    }
    let mut deserializer = serde_json::Deserializer::from_str(text);
    deserializer.disable_recursion_limit();
    let value = Value::deserialize(&mut deserializer).map_err(|error| error.to_string())?;
    deserializer.end().map_err(|error| error.to_string())?;
    Ok(value)
}

/// How deeply arrays and objects nest in `text`, brackets inside strings not
/// counted. Malformed text gives some number; the parser rejects it anyway.
fn max_nesting_depth(text: &str) -> usize {
    let (mut depth, mut deepest) = (0usize, 0usize);
    let (mut in_string, mut escaped) = (false, false);
    for byte in text.bytes() {
        if in_string {
            match byte {
                _ if escaped => escaped = false,
                b'\\' => escaped = true,
                b'"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'[' | b'{' => {
                depth += 1;
                deepest = deepest.max(depth);
            }
            b']' | b'}' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    deepest
}

/// Loads the mapping subtree of a config.json object, as the Swift app always
/// has (HK-011 to HK-014):
///
/// ```text
/// device = config["deviceMappings"]
/// mappings = if device is an object            // only an object wins, even {}
///                decode_device_mappings(device)  // tolerant per entry
///            else if config["mapping"] decodes strictly as a legacy mapping
///                {"dualsense": that mapping}     // lossless migration
///            else
///                default_device_mappings()
/// backup   = if device is present (null too)
///                !decodes_strictly(device)       // the save would drop something
///            else
///                config has a "mapping" key      // any value, null too: migration
/// ```
///
/// The backup rule is deliberately the Swift app's, quirks included: an
/// action with an unknown sibling key decodes, so it is not copied, and the
/// sibling is lost on the next save.
pub fn load_device_mappings_from(config: &Map<String, Value>) -> MappingLoad {
    let device = config.get(DEVICE_MAPPINGS_KEY);
    let device_mappings = match device.and_then(decode_device_mappings) {
        Some(mappings) => mappings,
        None => match config
            .get(LEGACY_MAPPING_KEY)
            .and_then(decode_legacy_mapping)
        {
            Some(mapping) => BTreeMap::from([(DUALSENSE_PROFILE_ID.to_owned(), mapping)]),
            None => default_device_mappings(),
        },
    };
    let backup_before_save = match device {
        Some(value) => !decodes_strictly(value),
        None => config.contains_key(LEGACY_MAPPING_KEY),
    };
    MappingLoad {
        device_mappings,
        backup_before_save,
    }
}

/// Reads `deviceMappings` tolerantly, entry by entry: `None` unless `value`
/// is an object; a profile whose value is not an object is dropped, and so is
/// a binding that is not an action (an action from a newer build, a
/// hand-edit). Everything else is kept (HK-011).
pub fn decode_device_mappings(value: &Value) -> Option<DeviceMappings> {
    let profiles = value.as_object()?;
    Some(
        profiles
            .iter()
            .filter_map(|(profile_id, mapping)| {
                let controls = mapping.as_object()?;
                let mapping = controls
                    .iter()
                    .filter_map(|(control_id, action)| {
                        Action::from_wire(action).map(|action| (control_id.clone(), action))
                    })
                    .collect();
                Some((profile_id.clone(), mapping))
            })
            .collect(),
    )
}

/// Reads a legacy button-keyed mapping, all or nothing: an object whose every
/// key is a DualSense control id and every value an action. Anything else is
/// `None`, and the caller falls back to the defaults (the HK-012 quirk, kept
/// knowingly). An empty object is an empty mapping.
pub fn decode_legacy_mapping(value: &Value) -> Option<DeviceMapping> {
    value
        .as_object()?
        .iter()
        .map(|(control_id, action)| {
            if !DUALSENSE_CONTROL_IDS.contains(&control_id.as_str()) {
                return None;
            }
            Some((control_id.clone(), Action::from_wire(action)?))
        })
        .collect()
}

/// Whether the tolerant read would keep everything: an object of objects of
/// actions.
pub fn decodes_strictly(value: &Value) -> bool {
    value.as_object().is_some_and(|profiles| {
        profiles.values().all(|mapping| {
            mapping.as_object().is_some_and(|controls| {
                controls
                    .values()
                    .all(|action| Action::from_wire(action).is_some())
            })
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn device_mappings_serialize_as_keyed_objects() {
        let value = serde_json::to_value(default_device_mappings()).unwrap();
        let dualsense = &value["dualsense"];
        assert!(value.is_object() && dualsense.is_object());
        assert_eq!(dualsense["r2"], json!({"pushToTalk": {}}));
        assert_eq!(
            dualsense["square"],
            json!({"sendPrompt": {"_0": "Continue"}})
        );
    }

    #[test]
    fn legacy_mapping_needs_dualsense_control_ids() {
        let known = json!({"r2": {"pushToTalk": {}}});
        assert_eq!(
            decode_legacy_mapping(&known),
            Some(BTreeMap::from([("r2".to_owned(), Action::PushToTalk)]))
        );
        let foreign = json!({"r2": {"pushToTalk": {}}, "key-1": {"approve": {}}});
        assert_eq!(decode_legacy_mapping(&foreign), None);
        assert_eq!(decode_legacy_mapping(&json!({})), Some(BTreeMap::new()));
    }

    #[test]
    fn the_default_mapping_binds_every_dualsense_control() {
        let mapping = default_mapping();
        let ids: Vec<&str> = mapping.keys().map(String::as_str).collect();
        let mut expected = DUALSENSE_CONTROL_IDS.to_vec();
        expected.sort_unstable();
        assert_eq!(ids, expected);
    }

    #[test]
    fn only_an_object_config_loads() {
        assert!(load_device_mappings("[]").is_err());
        assert!(load_device_mappings("not json").is_err());
        let load = load_device_mappings("{}").unwrap();
        assert_eq!(load.device_mappings, default_device_mappings());
        assert!(!load.backup_before_save);
    }

    /// `{"deviceMappings":{"dualsense":{"r2":{"approve":{"note":[[…]]}}}}}`,
    /// nested `depth` levels in all.
    fn nested_config(depth: usize) -> String {
        let arrays = depth - 5;
        format!(
            r#"{{"deviceMappings":{{"dualsense":{{"r2":{{"approve":{{"note":{}{}}}}}}}}}}}"#,
            "[".repeat(arrays),
            "]".repeat(arrays)
        )
    }

    #[test]
    fn a_deeply_nested_config_keeps_its_bindings() {
        // Past serde_json's default limit of 128, up to JSONDecoder's 512:
        // the Swift app has always read these, so the core must too.
        for depth in [127, 200, 400, MAX_CONFIG_DEPTH] {
            let load = load_device_mappings(&nested_config(depth)).unwrap();
            assert_eq!(
                resolve_action(&load.device_mappings, "dualsense", "r2"),
                Action::Approve,
                "depth {depth}"
            );
        }
        assert!(load_device_mappings(&nested_config(MAX_CONFIG_DEPTH + 1)).is_err());
    }

    #[test]
    fn the_deepest_config_fits_a_small_thread_stack() {
        // The app loads its config on the main thread (8 MiB of stack). A
        // release build fits this in 512 KiB; an unoptimised one in 1 MiB.
        let text = nested_config(MAX_CONFIG_DEPTH);
        let worker = std::thread::Builder::new()
            .stack_size(1024 * 1024)
            .spawn(move || load_device_mappings(&text).is_ok())
            .unwrap();
        assert!(worker.join().unwrap());
    }

    #[test]
    fn brackets_inside_strings_do_not_count_as_nesting() {
        assert_eq!(max_nesting_depth(r#"{"a":"[[[{{\"]]"}"#), 1);
        assert_eq!(max_nesting_depth(r#"[[],{"b":[1]}]"#), 3);
    }

    #[test]
    fn unmapped_resolves_to_none() {
        let mappings = default_device_mappings();
        assert_eq!(
            resolve_action(&mappings, "dualsense", "r2"),
            Action::PushToTalk
        );
        assert_eq!(resolve_action(&mappings, "dualsense", "zz"), Action::None);
        assert_eq!(resolve_action(&mappings, "pedal", "r2"), Action::None);
    }
}
