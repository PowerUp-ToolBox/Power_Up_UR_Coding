//! The configuration file (`config.json` on macOS): its full schema, its
//! defaults, how it reads (tolerantly, key by key) and the exact bytes it is
//! saved as. The platform owns the file: its path, the atomic write, the
//! save debounce and the backup copies. The core takes the bytes it read
//! and returns the values to run with plus what to do with the file (move a
//! corrupt one aside, copy one the next save would rewrite lossily), and
//! hands back the bytes to save.
//!
//! The rules are the Swift app's (DESIGN v2.14, `Tests/Fixtures/config/`):
//! the file is read as `JSONDecoder` reads it (`json::decoder`) and written
//! as `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` writes it
//! (`json::encoder`), so a file either app wrote saves back unchanged.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Map;

use crate::json::decoder::{read_document, Decoded};
use crate::json::encoder::to_swift_pretty;
use crate::mapping::{self, DeviceMappings, DEVICE_MAPPINGS_KEY, LEGACY_MAPPING_KEY};
use crate::session::cycles::DEFAULT_MODEL_CYCLE;
use crate::text;
use crate::CoreError;

/// Every setting the app persists. Strings are kept verbatim: values such as
/// `tts_voice_id`, the audio device UIDs and `remote_app_bundle_id` are a
/// platform's own identifiers, which the core never interprets (HK-159).
#[derive(Debug, Clone, PartialEq)]
pub struct AppConfig {
    /// The coding project folder; `None` until one is chosen.
    pub project_dir: Option<String>,
    pub model: String,
    pub permission_mode: String,
    /// A manual override of the claude binary's path.
    pub claude_path: Option<String>,
    /// The session the pre-multi-project build resumed (HK-164).
    pub last_session_id: Option<String>,
    pub tts_enabled: bool,
    /// The platform speech engine's rate (Apple's 0 to 1 scale on macOS).
    pub tts_rate: f32,
    pub tts_voice_id: Option<String>,
    /// The spoken reply's length cap; 0 is no limit.
    pub max_spoken_chars: i64,
    pub speak_summaries: bool,
    pub summary_model: String,
    pub locale_id: String,
    pub on_device_recognition: bool,
    pub audio_input_uid: Option<String>,
    pub audio_output_uid: Option<String>,
    /// The Controller slot's pin; `None` is Automatic (DESIGN v2.7 B).
    pub controller_device_id: Option<String>,
    pub haptics_enabled: bool,
    pub light_enabled: bool,
    pub effort: String,
    pub model_cycle: Vec<String>,
    pub harness_kind: String,
    pub acp_agent: String,
    pub acp_custom_command: String,
    pub control_mode: String,
    pub remote_target_kind: String,
    pub remote_cmux_workspace: Option<String>,
    pub remote_cmux_surface: Option<String>,
    pub remote_app_bundle_id: Option<String>,
    pub remote_cmux_password: Option<String>,
    pub remote_auto_submit: bool,
    pub listener_port: i64,
    /// The hook read-back secret; the platform mints one when it is empty.
    pub listener_token: String,
    /// Most recent first.
    pub recent_project_dirs: Vec<String>,
    pub session_ids_by_project: BTreeMap<String, String>,
    pub device_mappings: DeviceMappings,
}

/// The default speech rate: AVSpeechUtteranceDefaultSpeechRate, kept as a
/// literal so the core never depends on Apple's framework (HK-159).
pub const DEFAULT_TTS_RATE: f32 = 0.5;

/// The port the hook read-back listener binds on 127.0.0.1 by default.
pub const DEFAULT_LISTENER_PORT: i64 = 48738;

/// The summary model a blank setting falls back to (HK-158).
pub const DEFAULT_SUMMARY_MODEL: &str = "haiku";

/// The harnesses a session can run on.
pub const HARNESS_KINDS: [&str; 2] = ["claude", "acp"];

/// The preset ACP agents, plus a custom command.
pub const ACP_AGENTS: [&str; 4] = ["opencode", "claudeBridge", "codexBridge", "custom"];

/// Where controller and voice input goes.
pub const CONTROL_MODES: [&str; 2] = ["builtin", "remote"];

/// How remote mode reaches its session, in the order Settings offers them.
pub const REMOTE_TARGET_KINDS: [&str; 3] = ["cmux", "app", "frontmost"];

impl Default for AppConfig {
    fn default() -> Self {
        AppConfig {
            project_dir: None,
            model: "default".to_owned(),
            permission_mode: "acceptEdits".to_owned(),
            claude_path: None,
            last_session_id: None,
            tts_enabled: true,
            tts_rate: DEFAULT_TTS_RATE,
            tts_voice_id: None,
            max_spoken_chars: 1500,
            speak_summaries: false,
            summary_model: DEFAULT_SUMMARY_MODEL.to_owned(),
            locale_id: "en-US".to_owned(),
            on_device_recognition: false,
            audio_input_uid: None,
            audio_output_uid: None,
            controller_device_id: None,
            haptics_enabled: true,
            light_enabled: true,
            effort: "default".to_owned(),
            model_cycle: DEFAULT_MODEL_CYCLE.iter().map(|&m| m.to_owned()).collect(),
            harness_kind: HARNESS_KINDS[0].to_owned(),
            acp_agent: ACP_AGENTS[0].to_owned(),
            acp_custom_command: String::new(),
            control_mode: CONTROL_MODES[0].to_owned(),
            remote_target_kind: REMOTE_TARGET_KINDS[0].to_owned(),
            remote_cmux_workspace: None,
            remote_cmux_surface: None,
            remote_app_bundle_id: None,
            remote_cmux_password: None,
            remote_auto_submit: true,
            listener_port: DEFAULT_LISTENER_PORT,
            // The platform mints the token when it loads a config without
            // one (HK-168), so an empty one is never saved for long.
            listener_token: String::new(),
            recent_project_dirs: Vec::new(),
            session_ids_by_project: BTreeMap::new(),
            device_mappings: mapping::default_device_mappings(),
        }
    }
}

/// What reading the file's bytes decided.
// Made once per launch and taken apart at once, so the size of the loaded
// variant costs nothing worth a box.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum ConfigLoad {
    /// The config to run with, and whether the file must be copied (to
    /// `config.pre-profiles.json` on macOS, once) before the next save
    /// rewrites it lossily (HK-014).
    Loaded {
        config: AppConfig,
        backup_before_save: bool,
    },
    /// Not a document JSONDecoder reads, or not an object: the platform
    /// moves the file aside and runs on the defaults (HK-160).
    Corrupt,
}

/// Reads config.json's bytes as the Swift app always has (HK-155 to
/// HK-159). The file is corrupt when it does not scan, its root is not an
/// object or one of the root's keys does not convert. Every key is optional
/// and read on its own: a missing key, a
/// null, a value of the wrong type or one that does not convert takes the
/// key's default and never costs the rest of the file. Optional strings
/// read empty as absent; `summaryModel` is trimmed and falls back to haiku
/// when blank; the four fixed vocabularies must match one of their values
/// exactly; `listenerPort` must be 1 to 65535. The mapping subtree loads
/// through [`mapping::load_device_mappings_from`], which also decides the
/// backup. Unknown keys are read past and never saved.
pub fn load_config(bytes: &[u8]) -> ConfigLoad {
    let Some(root) = read_document(bytes) else {
        return ConfigLoad::Corrupt;
    };
    // The root's keys are all converted when it is read, so one bad key
    // fails the file; a nested object's keys only fail the field reading it.
    let Some(keyed) = root.keyed() else {
        return ConfigLoad::Corrupt;
    };
    let defaults = AppConfig::default();
    let get = |key: &str| keyed.get(key);
    let optional = |key: &str| {
        get(key)
            .and_then(Decoded::as_string)
            .filter(|text| !text.is_empty())
    };
    let string = |key: &str, default: &str| {
        get(key)
            .and_then(Decoded::as_string)
            .unwrap_or_else(|| default.to_owned())
    };
    let flag = |key: &str, default: bool| get(key).and_then(Decoded::as_bool).unwrap_or(default);
    let option = |key: &str, allowed: &[&str], default: &str| {
        let raw = string(key, default);
        if allowed.contains(&raw.as_str()) {
            raw
        } else {
            default.to_owned()
        }
    };
    let summary_model = {
        let raw = string("summaryModel", &defaults.summary_model);
        let trimmed = text::trim(&raw);
        if trimmed.is_empty() {
            defaults.summary_model.clone()
        } else {
            trimmed.to_owned()
        }
    };
    let listener_port = get("listenerPort")
        .and_then(Decoded::as_int)
        .filter(|port| (1..=65535).contains(port))
        .unwrap_or(DEFAULT_LISTENER_PORT);

    // The mapping subtree goes to the mapping layer as the app's JSONValue
    // read it: only the keys present, a null kept apart from a missing key.
    let mut subtree = Map::new();
    for key in [DEVICE_MAPPINGS_KEY, LEGACY_MAPPING_KEY] {
        if let Some(value) = get(key) {
            subtree.insert(key.to_owned(), value.to_mapping_value());
        }
    }
    let mappings = mapping::load_device_mappings_from(&subtree);

    let config = AppConfig {
        project_dir: optional("projectDir"),
        model: string("model", &defaults.model),
        permission_mode: string("permissionMode", &defaults.permission_mode),
        claude_path: optional("claudePath"),
        last_session_id: optional("lastSessionID"),
        tts_enabled: flag("ttsEnabled", defaults.tts_enabled),
        tts_rate: get("ttsRate")
            .and_then(Decoded::as_float)
            .unwrap_or(defaults.tts_rate),
        tts_voice_id: optional("ttsVoiceID"),
        max_spoken_chars: get("maxSpokenChars")
            .and_then(Decoded::as_int)
            .unwrap_or(defaults.max_spoken_chars),
        speak_summaries: flag("speakSummaries", defaults.speak_summaries),
        summary_model,
        locale_id: string("localeID", &defaults.locale_id),
        on_device_recognition: flag("onDeviceRecognition", defaults.on_device_recognition),
        audio_input_uid: optional("audioInputUID"),
        audio_output_uid: optional("audioOutputUID"),
        controller_device_id: optional("controllerDeviceID"),
        haptics_enabled: flag("hapticsEnabled", defaults.haptics_enabled),
        light_enabled: flag("lightEnabled", defaults.light_enabled),
        effort: string("effort", &defaults.effort),
        model_cycle: get("modelCycle")
            .and_then(Decoded::as_string_array)
            .unwrap_or_else(|| defaults.model_cycle.clone()),
        harness_kind: option("harnessKind", &HARNESS_KINDS, &defaults.harness_kind),
        acp_agent: option("acpAgent", &ACP_AGENTS, &defaults.acp_agent),
        acp_custom_command: string("acpCustomCommand", &defaults.acp_custom_command),
        control_mode: option("controlMode", &CONTROL_MODES, &defaults.control_mode),
        remote_target_kind: option(
            "remoteTargetKind",
            &REMOTE_TARGET_KINDS,
            &defaults.remote_target_kind,
        ),
        remote_cmux_workspace: optional("remoteCmuxWorkspace"),
        remote_cmux_surface: optional("remoteCmuxSurface"),
        remote_app_bundle_id: optional("remoteAppBundleID"),
        remote_cmux_password: optional("remoteCmuxPassword"),
        remote_auto_submit: flag("remoteAutoSubmit", defaults.remote_auto_submit),
        listener_port,
        listener_token: string("listenerToken", &defaults.listener_token),
        recent_project_dirs: get("recentProjectDirs")
            .and_then(Decoded::as_string_array)
            .unwrap_or_default(),
        session_ids_by_project: get("sessionIDsByProject")
            .and_then(Decoded::as_string_map)
            .unwrap_or_default(),
        device_mappings: mappings.device_mappings,
    };
    ConfigLoad::Loaded {
        config,
        backup_before_save: mappings.backup_before_save,
    }
}

/// config.json as written. The fields are declared in the order
/// `.sortedKeys` writes them (Unicode scalar order, so `controlMode` comes
/// before `controllerDeviceID`); a test checks that order, so a new field
/// declared out of place fails at once. A `None` is left out, as Swift's
/// synthesized encoder leaves out a nil optional.
#[derive(Serialize)]
struct ConfigFile<'a> {
    #[serde(rename = "acpAgent")]
    acp_agent: &'a str,
    #[serde(rename = "acpCustomCommand")]
    acp_custom_command: &'a str,
    #[serde(rename = "audioInputUID", skip_serializing_if = "Option::is_none")]
    audio_input_uid: Option<&'a str>,
    #[serde(rename = "audioOutputUID", skip_serializing_if = "Option::is_none")]
    audio_output_uid: Option<&'a str>,
    #[serde(rename = "claudePath", skip_serializing_if = "Option::is_none")]
    claude_path: Option<&'a str>,
    #[serde(rename = "controlMode")]
    control_mode: &'a str,
    #[serde(rename = "controllerDeviceID", skip_serializing_if = "Option::is_none")]
    controller_device_id: Option<&'a str>,
    #[serde(rename = "deviceMappings")]
    device_mappings: &'a DeviceMappings,
    effort: &'a str,
    #[serde(rename = "hapticsEnabled")]
    haptics_enabled: bool,
    #[serde(rename = "harnessKind")]
    harness_kind: &'a str,
    #[serde(rename = "lastSessionID", skip_serializing_if = "Option::is_none")]
    last_session_id: Option<&'a str>,
    #[serde(rename = "lightEnabled")]
    light_enabled: bool,
    #[serde(rename = "listenerPort")]
    listener_port: i64,
    #[serde(rename = "listenerToken")]
    listener_token: &'a str,
    #[serde(rename = "localeID")]
    locale_id: &'a str,
    #[serde(rename = "maxSpokenChars")]
    max_spoken_chars: i64,
    model: &'a str,
    #[serde(rename = "modelCycle")]
    model_cycle: &'a [String],
    #[serde(rename = "onDeviceRecognition")]
    on_device_recognition: bool,
    #[serde(rename = "permissionMode")]
    permission_mode: &'a str,
    #[serde(rename = "projectDir", skip_serializing_if = "Option::is_none")]
    project_dir: Option<&'a str>,
    #[serde(rename = "recentProjectDirs")]
    recent_project_dirs: &'a [String],
    #[serde(rename = "remoteAppBundleID", skip_serializing_if = "Option::is_none")]
    remote_app_bundle_id: Option<&'a str>,
    #[serde(rename = "remoteAutoSubmit")]
    remote_auto_submit: bool,
    #[serde(rename = "remoteCmuxPassword", skip_serializing_if = "Option::is_none")]
    remote_cmux_password: Option<&'a str>,
    #[serde(rename = "remoteCmuxSurface", skip_serializing_if = "Option::is_none")]
    remote_cmux_surface: Option<&'a str>,
    #[serde(
        rename = "remoteCmuxWorkspace",
        skip_serializing_if = "Option::is_none"
    )]
    remote_cmux_workspace: Option<&'a str>,
    #[serde(rename = "remoteTargetKind")]
    remote_target_kind: &'a str,
    #[serde(rename = "sessionIDsByProject")]
    session_ids_by_project: &'a BTreeMap<String, String>,
    #[serde(rename = "speakSummaries")]
    speak_summaries: bool,
    #[serde(rename = "summaryModel")]
    summary_model: &'a str,
    #[serde(rename = "ttsEnabled")]
    tts_enabled: bool,
    #[serde(rename = "ttsRate")]
    tts_rate: f32,
    #[serde(rename = "ttsVoiceID", skip_serializing_if = "Option::is_none")]
    tts_voice_id: Option<&'a str>,
}

/// The bytes config.json holds for `config` (HK-162): JSONEncoder's pretty,
/// key-sorted text, nil optionals left out, no trailing newline. Fails only
/// for a speech rate that is not a finite number, which JSONEncoder refuses
/// too.
pub fn encode_config(config: &AppConfig) -> Result<String, CoreError> {
    if !config.tts_rate.is_finite() {
        return Err(CoreError::Failed {
            message: format!("ttsRate {} is not a finite number", config.tts_rate),
        });
    }
    to_swift_pretty(&ConfigFile {
        acp_agent: &config.acp_agent,
        acp_custom_command: &config.acp_custom_command,
        audio_input_uid: config.audio_input_uid.as_deref(),
        audio_output_uid: config.audio_output_uid.as_deref(),
        claude_path: config.claude_path.as_deref(),
        control_mode: &config.control_mode,
        controller_device_id: config.controller_device_id.as_deref(),
        device_mappings: &config.device_mappings,
        effort: &config.effort,
        haptics_enabled: config.haptics_enabled,
        harness_kind: &config.harness_kind,
        last_session_id: config.last_session_id.as_deref(),
        light_enabled: config.light_enabled,
        listener_port: config.listener_port,
        listener_token: &config.listener_token,
        locale_id: &config.locale_id,
        max_spoken_chars: config.max_spoken_chars,
        model: &config.model,
        model_cycle: &config.model_cycle,
        on_device_recognition: config.on_device_recognition,
        permission_mode: &config.permission_mode,
        project_dir: config.project_dir.as_deref(),
        recent_project_dirs: &config.recent_project_dirs,
        remote_app_bundle_id: config.remote_app_bundle_id.as_deref(),
        remote_auto_submit: config.remote_auto_submit,
        remote_cmux_password: config.remote_cmux_password.as_deref(),
        remote_cmux_surface: config.remote_cmux_surface.as_deref(),
        remote_cmux_workspace: config.remote_cmux_workspace.as_deref(),
        remote_target_kind: &config.remote_target_kind,
        session_ids_by_project: &config.session_ids_by_project,
        speak_summaries: config.speak_summaries,
        summary_model: &config.summary_model,
        tts_enabled: config.tts_enabled,
        tts_rate: config.tts_rate,
        tts_voice_id: config.tts_voice_id.as_deref(),
    })
}

/// The pre-multi-project migration (HK-164), run once a config is loaded:
/// with a project folder chosen, the folder joins the front of the recents
/// when it is not there yet, and the stored `lastSessionID` becomes the
/// folder's session when it has none. Otherwise the config is unchanged.
pub fn seed_project_bookkeeping(config: &AppConfig) -> AppConfig {
    let mut seeded = config.clone();
    let Some(dir) = config.project_dir.as_deref().filter(|dir| !dir.is_empty()) else {
        return seeded;
    };
    if !seeded
        .recent_project_dirs
        .iter()
        .any(|recent| recent == dir)
    {
        seeded.recent_project_dirs.insert(0, dir.to_owned());
    }
    if let Some(last) = &config.last_session_id {
        seeded
            .session_ids_by_project
            .entry(dir.to_owned())
            .or_insert_with(|| last.clone());
    }
    seeded
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loaded(text: &str) -> (AppConfig, bool) {
        match load_config(text.as_bytes()) {
            ConfigLoad::Loaded {
                config,
                backup_before_save,
            } => (config, backup_before_save),
            ConfigLoad::Corrupt => panic!("corrupt: {text}"),
        }
    }

    #[test]
    fn every_key_is_written_in_scalar_order() {
        let config = AppConfig {
            project_dir: Some("p".into()),
            claude_path: Some("c".into()),
            last_session_id: Some("s".into()),
            tts_voice_id: Some("v".into()),
            audio_input_uid: Some("i".into()),
            audio_output_uid: Some("o".into()),
            controller_device_id: Some("d".into()),
            remote_cmux_workspace: Some("w".into()),
            remote_cmux_surface: Some("f".into()),
            remote_app_bundle_id: Some("b".into()),
            remote_cmux_password: Some("x".into()),
            ..AppConfig::default()
        };
        let text = encode_config(&config).unwrap();
        let keys: Vec<&str> = text
            .lines()
            .filter(|line| line.starts_with("  \"") && !line.starts_with("   "))
            .filter_map(|line| line.split('"').nth(1))
            .collect();
        assert_eq!(keys.len(), 35, "{keys:?}");
        let mut sorted = keys.clone();
        sorted.sort_unstable();
        assert_eq!(keys, sorted);
    }

    #[test]
    fn the_defaults_round_trip() {
        let text = encode_config(&AppConfig::default()).unwrap();
        assert_eq!(loaded(&text), (AppConfig::default(), false));
        assert!(!text.contains("controllerDeviceID"));
        assert!(text.contains("\"ttsRate\" : 0.5\n}"));
    }

    #[test]
    fn a_non_finite_rate_is_refused() {
        let config = AppConfig {
            tts_rate: f32::NAN,
            ..AppConfig::default()
        };
        assert!(encode_config(&config).is_err());
    }

    #[test]
    fn only_an_object_loads() {
        for corrupt in ["[]", "\"s\"", "null", "1", "", "{"] {
            assert_eq!(
                load_config(corrupt.as_bytes()),
                ConfigLoad::Corrupt,
                "{corrupt}"
            );
        }
    }

    #[test]
    fn canonically_equivalent_keys_are_kept_apart() {
        // Swift's dictionary would merge these two spellings of /é into one
        // entry (HK-415); the core keeps both, so nothing is lost.
        let (config, _) =
            loaded("{\"sessionIDsByProject\":{\"/\u{e9}\":\"a\",\"/e\u{301}\":\"b\"}}");
        assert_eq!(config.session_ids_by_project.len(), 2);
    }

    #[test]
    fn the_project_bookkeeping_is_seeded_once() {
        let config = AppConfig {
            project_dir: Some("/p".into()),
            last_session_id: Some("s1".into()),
            recent_project_dirs: vec!["/q".into()],
            ..AppConfig::default()
        };
        let seeded = seed_project_bookkeeping(&config);
        assert_eq!(seeded.recent_project_dirs, ["/p", "/q"]);
        assert_eq!(
            seeded.session_ids_by_project.get("/p").map(String::as_str),
            Some("s1")
        );
        assert_eq!(seed_project_bookkeeping(&seeded), seeded);

        let mut kept = config.clone();
        kept.session_ids_by_project.insert("/p".into(), "s0".into());
        kept.recent_project_dirs = vec!["/q".into(), "/p".into()];
        let seeded = seed_project_bookkeeping(&kept);
        assert_eq!(seeded, kept, "a known folder and its own session stay");

        let none = AppConfig::default();
        assert_eq!(seed_project_bookkeeping(&none), none);
        let empty = AppConfig {
            project_dir: Some(String::new()),
            ..AppConfig::default()
        };
        assert_eq!(seed_project_bookkeeping(&empty), empty);
    }
}
