//! The configuration schema (slice 2.5): the defaults, reading config.json's
//! bytes, the bytes it is saved as, the pre-multi-project migration and the
//! fixed vocabularies Settings offers.
//!
//! `CoreAppConfig` is the uniffi face of `powerup_core::config::AppConfig`,
//! field for field (uniffi spells `last_session_id` as `lastSessionId` in
//! Swift; the app's `AppConfig` keeps its own names, DESIGN v2.14 A). The
//! file itself stays with the app: these functions take and return bytes.

use std::collections::HashMap;

use powerup_core::config::{self, AppConfig, ConfigLoad};

use crate::mapping::{to_bridge_mappings, to_core_mappings, CoreDeviceMappings};
use crate::{contain, CoreBridgeError};

/// Every persisted setting, as `powerup_core::config::AppConfig` holds it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreAppConfig {
    pub project_dir: Option<String>,
    pub model: String,
    pub permission_mode: String,
    pub claude_path: Option<String>,
    pub last_session_id: Option<String>,
    pub tts_enabled: bool,
    pub tts_rate: f32,
    pub tts_voice_id: Option<String>,
    pub max_spoken_chars: i64,
    pub speak_summaries: bool,
    pub summary_model: String,
    pub locale_id: String,
    pub on_device_recognition: bool,
    pub audio_input_uid: Option<String>,
    pub audio_output_uid: Option<String>,
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
    pub listener_token: String,
    pub recent_project_dirs: Vec<String>,
    pub session_ids_by_project: HashMap<String, String>,
    pub device_mappings: CoreDeviceMappings,
}

/// What reading config.json's bytes decided.
// Crosses the bridge once per launch; uniffi carries the record by value
// either way, so a box would buy nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreConfigLoad {
    /// The config to run with, and whether the file must be copied once
    /// (config.pre-profiles.json) before the next save rewrites it.
    Loaded {
        config: CoreAppConfig,
        backup_before_save: bool,
    },
    /// Not a config the app can read: the file is moved aside
    /// (config.json.bak) and the defaults apply.
    Corrupt,
}

/// The values each fixed-vocabulary setting may take, in the order Settings
/// offers them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreConfigVocabulary {
    pub harness_kinds: Vec<String>,
    pub acp_agents: Vec<String>,
    pub control_modes: Vec<String>,
    pub remote_target_kinds: Vec<String>,
}

impl From<AppConfig> for CoreAppConfig {
    fn from(config: AppConfig) -> Self {
        CoreAppConfig {
            project_dir: config.project_dir,
            model: config.model,
            permission_mode: config.permission_mode,
            claude_path: config.claude_path,
            last_session_id: config.last_session_id,
            tts_enabled: config.tts_enabled,
            tts_rate: config.tts_rate,
            tts_voice_id: config.tts_voice_id,
            max_spoken_chars: config.max_spoken_chars,
            speak_summaries: config.speak_summaries,
            summary_model: config.summary_model,
            locale_id: config.locale_id,
            on_device_recognition: config.on_device_recognition,
            audio_input_uid: config.audio_input_uid,
            audio_output_uid: config.audio_output_uid,
            controller_device_id: config.controller_device_id,
            haptics_enabled: config.haptics_enabled,
            light_enabled: config.light_enabled,
            effort: config.effort,
            model_cycle: config.model_cycle,
            harness_kind: config.harness_kind,
            acp_agent: config.acp_agent,
            acp_custom_command: config.acp_custom_command,
            control_mode: config.control_mode,
            remote_target_kind: config.remote_target_kind,
            remote_cmux_workspace: config.remote_cmux_workspace,
            remote_cmux_surface: config.remote_cmux_surface,
            remote_app_bundle_id: config.remote_app_bundle_id,
            remote_cmux_password: config.remote_cmux_password,
            remote_auto_submit: config.remote_auto_submit,
            listener_port: config.listener_port,
            listener_token: config.listener_token,
            recent_project_dirs: config.recent_project_dirs,
            session_ids_by_project: config.session_ids_by_project.into_iter().collect(),
            device_mappings: to_bridge_mappings(config.device_mappings),
        }
    }
}

impl From<CoreAppConfig> for AppConfig {
    fn from(config: CoreAppConfig) -> Self {
        AppConfig {
            project_dir: config.project_dir,
            model: config.model,
            permission_mode: config.permission_mode,
            claude_path: config.claude_path,
            last_session_id: config.last_session_id,
            tts_enabled: config.tts_enabled,
            tts_rate: config.tts_rate,
            tts_voice_id: config.tts_voice_id,
            max_spoken_chars: config.max_spoken_chars,
            speak_summaries: config.speak_summaries,
            summary_model: config.summary_model,
            locale_id: config.locale_id,
            on_device_recognition: config.on_device_recognition,
            audio_input_uid: config.audio_input_uid,
            audio_output_uid: config.audio_output_uid,
            controller_device_id: config.controller_device_id,
            haptics_enabled: config.haptics_enabled,
            light_enabled: config.light_enabled,
            effort: config.effort,
            model_cycle: config.model_cycle,
            harness_kind: config.harness_kind,
            acp_agent: config.acp_agent,
            acp_custom_command: config.acp_custom_command,
            control_mode: config.control_mode,
            remote_target_kind: config.remote_target_kind,
            remote_cmux_workspace: config.remote_cmux_workspace,
            remote_cmux_surface: config.remote_cmux_surface,
            remote_app_bundle_id: config.remote_app_bundle_id,
            remote_cmux_password: config.remote_cmux_password,
            remote_auto_submit: config.remote_auto_submit,
            listener_port: config.listener_port,
            listener_token: config.listener_token,
            recent_project_dirs: config.recent_project_dirs,
            session_ids_by_project: config.session_ids_by_project.into_iter().collect(),
            device_mappings: to_core_mappings(config.device_mappings),
        }
    }
}

impl From<ConfigLoad> for CoreConfigLoad {
    fn from(load: ConfigLoad) -> Self {
        match load {
            ConfigLoad::Loaded {
                config,
                backup_before_save,
            } => CoreConfigLoad::Loaded {
                config: config.into(),
                backup_before_save,
            },
            ConfigLoad::Corrupt => CoreConfigLoad::Corrupt,
        }
    }
}

/// A fresh config: every setting at its default (`AppConfig::default`).
#[uniffi::export]
pub fn default_config() -> Result<CoreAppConfig, CoreBridgeError> {
    contain(|| Ok(AppConfig::default().into()))
}

/// Reads config.json's bytes as the app always has (`config::load_config`).
#[uniffi::export]
pub fn load_config(bytes: Vec<u8>) -> Result<CoreConfigLoad, CoreBridgeError> {
    contain(|| Ok(config::load_config(&bytes).into()))
}

/// The bytes config.json is saved as (`config::encode_config`): pretty,
/// key-sorted UTF-8 with no trailing newline.
#[uniffi::export]
pub fn encode_config(config: CoreAppConfig) -> Result<Vec<u8>, CoreBridgeError> {
    contain(|| config::encode_config(&config.into()).map(String::into_bytes))
}

/// The pre-multi-project migration (`config::seed_project_bookkeeping`).
#[uniffi::export]
pub fn seed_project_bookkeeping(config: CoreAppConfig) -> Result<CoreAppConfig, CoreBridgeError> {
    contain(|| Ok(config::seed_project_bookkeeping(&config.into()).into()))
}

/// The fixed vocabularies, so a new value is added in the core once.
#[uniffi::export]
pub fn config_vocabulary() -> Result<CoreConfigVocabulary, CoreBridgeError> {
    let list = |values: &[&str]| values.iter().map(|&value| value.to_owned()).collect();
    contain(|| {
        Ok(CoreConfigVocabulary {
            harness_kinds: list(&config::HARNESS_KINDS),
            acp_agents: list(&config::ACP_AGENTS),
            control_modes: list(&config::CONTROL_MODES),
            remote_target_kinds: list(&config::REMOTE_TARGET_KINDS),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_config_round_trips_through_the_bridge_type() {
        let mut config = AppConfig {
            project_dir: Some("/p".into()),
            controller_device_id: Some("pad".into()),
            tts_rate: 0.55,
            max_spoken_chars: -5,
            ..AppConfig::default()
        };
        config
            .session_ids_by_project
            .insert("/p".into(), "s".into());
        let back: AppConfig = CoreAppConfig::from(config.clone()).into();
        assert_eq!(back, config);
    }

    #[test]
    fn loading_saving_and_seeding_go_through_the_core() {
        let defaults = default_config().unwrap();
        let bytes = encode_config(defaults.clone()).unwrap();
        assert!(bytes.starts_with(b"{\n  \"acpAgent\" : \"opencode\""));
        assert_eq!(
            load_config(bytes).unwrap(),
            CoreConfigLoad::Loaded {
                config: defaults,
                backup_before_save: false
            }
        );
        assert_eq!(
            load_config(b"[]".to_vec()).unwrap(),
            CoreConfigLoad::Corrupt
        );
        let legacy = br#"{"mapping":{"r2":{"approve":{}}}}"#.to_vec();
        assert!(matches!(
            load_config(legacy).unwrap(),
            CoreConfigLoad::Loaded {
                backup_before_save: true,
                ..
            }
        ));
        let mut config = default_config().unwrap();
        config.project_dir = Some("/p".into());
        config.last_session_id = Some("s".into());
        let seeded = seed_project_bookkeeping(config).unwrap();
        assert_eq!(seeded.recent_project_dirs, ["/p"]);
        assert_eq!(
            seeded.session_ids_by_project.get("/p").map(String::as_str),
            Some("s")
        );
    }

    #[test]
    fn a_non_finite_rate_is_an_error() {
        let mut config = default_config().unwrap();
        config.tts_rate = f32::INFINITY;
        assert!(matches!(
            encode_config(config),
            Err(CoreBridgeError::Failed { .. })
        ));
    }

    #[test]
    fn the_vocabulary_is_the_cores() {
        let vocabulary = config_vocabulary().unwrap();
        assert_eq!(vocabulary.remote_target_kinds, ["cmux", "app", "frontmost"]);
        assert_eq!(vocabulary.control_modes, ["builtin", "remote"]);
        assert_eq!(vocabulary.harness_kinds, ["claude", "acp"]);
        assert_eq!(
            vocabulary.acp_agents,
            ["opencode", "claudeBridge", "codexBridge", "custom"]
        );
    }
}
