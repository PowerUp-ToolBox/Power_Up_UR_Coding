//! The Claude Code hooks (slice 2.5): the command registered, the hook
//! script, what installing or removing the hooks does to
//! `~/.claude/settings.json`, and whether they are installed. The files
//! stay with the app: these functions take and return bytes and strings
//! (DESIGN v2.14 A).

use powerup_core::hooks::{self, InstallState, SettingsEdit, SettingsRefusal, HOOK_EVENTS};

use crate::{contain, CoreBridgeError};

/// How the registered hooks relate to the port and token in use now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreHookInstallState {
    NotInstalled,
    Installed,
    OutOfDate,
}

/// Why an edit left the settings file alone.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSettingsRefusal {
    InvalidJson,
    HooksNotAnObject,
    EventNotAnArray { event: String },
}

/// What an install or uninstall does to the settings file: nothing, the
/// whole new file as compact UTF-8 JSON for the app's writer to format, or
/// a refusal.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSettingsEdit {
    Unchanged,
    Write { json: Vec<u8> },
    Refused { refusal: CoreSettingsRefusal },
}

impl From<InstallState> for CoreHookInstallState {
    fn from(state: InstallState) -> Self {
        match state {
            InstallState::NotInstalled => CoreHookInstallState::NotInstalled,
            InstallState::Installed => CoreHookInstallState::Installed,
            InstallState::OutOfDate => CoreHookInstallState::OutOfDate,
        }
    }
}

impl From<SettingsRefusal> for CoreSettingsRefusal {
    fn from(refusal: SettingsRefusal) -> Self {
        match refusal {
            SettingsRefusal::InvalidJson => CoreSettingsRefusal::InvalidJson,
            SettingsRefusal::HooksNotAnObject => CoreSettingsRefusal::HooksNotAnObject,
            SettingsRefusal::EventNotAnArray { event } => {
                CoreSettingsRefusal::EventNotAnArray { event }
            }
        }
    }
}

impl From<SettingsEdit> for CoreSettingsEdit {
    fn from(edit: SettingsEdit) -> Self {
        match edit {
            SettingsEdit::Unchanged => CoreSettingsEdit::Unchanged,
            SettingsEdit::Write { json } => CoreSettingsEdit::Write {
                json: json.into_bytes(),
            },
            SettingsEdit::Refused(refusal) => CoreSettingsEdit::Refused {
                refusal: refusal.into(),
            },
        }
    }
}

/// The hook events PowerUp registers, in their stable order.
#[uniffi::export]
pub fn hook_events() -> Result<Vec<String>, CoreBridgeError> {
    contain(|| {
        Ok(HOOK_EVENTS
            .iter()
            .map(|event| (*event).to_owned())
            .collect())
    })
}

/// The command registered for the hook script at `script_path`.
#[uniffi::export]
pub fn hook_command(script_path: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(hooks::hook_command(&script_path)))
}

/// The hook script's text for a listener port and token.
#[uniffi::export]
pub fn hook_script_body(port: i64, token: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(hooks::hook_script_body(port, &token)))
}

/// Whether the Stop hook points at the script; `settings` is the file's
/// bytes, nil for no file.
#[uniffi::export]
pub fn hooks_installed(
    settings: Option<Vec<u8>>,
    script_path: String,
) -> Result<bool, CoreBridgeError> {
    contain(|| Ok(hooks::is_installed(settings.as_deref(), &script_path)))
}

/// The full install state; `script_on_disk` is the script file's bytes,
/// nil when there is none.
#[uniffi::export]
pub fn hook_install_state(
    settings: Option<Vec<u8>>,
    script_path: String,
    script_on_disk: Option<Vec<u8>>,
    port: i64,
    token: String,
) -> Result<CoreHookInstallState, CoreBridgeError> {
    contain(|| {
        Ok(hooks::install_state(
            settings.as_deref(),
            &script_path,
            script_on_disk.as_deref(),
            port,
            &token,
        )
        .into())
    })
}

/// What installing the hooks does to the settings file.
#[uniffi::export]
pub fn hook_install_edit(
    settings: Option<Vec<u8>>,
    script_path: String,
) -> Result<CoreSettingsEdit, CoreBridgeError> {
    contain(|| hooks::install_edit(settings.as_deref(), &script_path).map(Into::into))
}

/// What removing the hooks does to the settings file.
#[uniffi::export]
pub fn hook_uninstall_edit(
    settings: Option<Vec<u8>>,
    script_path: String,
) -> Result<CoreSettingsEdit, CoreBridgeError> {
    contain(|| hooks::uninstall_edit(settings.as_deref(), &script_path).map(Into::into))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATH: &str = "/tmp/x y/powerup-hook.sh";

    #[test]
    fn an_install_round_trips_through_the_bridge() {
        let CoreSettingsEdit::Write { json } = hook_install_edit(None, PATH.into()).unwrap() else {
            panic!("a fresh install writes");
        };
        assert_eq!(
            hook_install_edit(Some(json.clone()), PATH.into()).unwrap(),
            CoreSettingsEdit::Unchanged
        );
        assert!(hooks_installed(Some(json.clone()), PATH.into()).unwrap());
        let script = hook_script_body(48738, "tok".into()).unwrap().into_bytes();
        assert_eq!(
            hook_install_state(
                Some(json.clone()),
                PATH.into(),
                Some(script),
                48738,
                "tok".into()
            )
            .unwrap(),
            CoreHookInstallState::Installed
        );
        assert_eq!(
            hook_uninstall_edit(Some(json), PATH.into()).unwrap(),
            CoreSettingsEdit::Write {
                json: b"{}".to_vec()
            }
        );
    }

    #[test]
    fn refusals_name_their_reason() {
        assert_eq!(
            hook_install_edit(Some(b"[]".to_vec()), PATH.into()).unwrap(),
            CoreSettingsEdit::Refused {
                refusal: CoreSettingsRefusal::InvalidJson
            }
        );
        assert_eq!(
            hook_install_edit(Some(br#"{"hooks":{"Stop":{}}}"#.to_vec()), PATH.into()).unwrap(),
            CoreSettingsEdit::Refused {
                refusal: CoreSettingsRefusal::EventNotAnArray {
                    event: "Stop".into()
                }
            }
        );
        assert_eq!(
            hook_uninstall_edit(Some(br#"{"hooks":null}"#.to_vec()), PATH.into()).unwrap(),
            CoreSettingsEdit::Refused {
                refusal: CoreSettingsRefusal::HooksNotAnObject
            }
        );
        assert_eq!(
            hook_uninstall_edit(None, PATH.into()).unwrap(),
            CoreSettingsEdit::Unchanged
        );
    }

    #[test]
    fn events_command_and_script() {
        assert_eq!(
            hook_events().unwrap(),
            [
                "Stop",
                "UserPromptSubmit",
                "Notification",
                "SessionEnd",
                "PostToolUse"
            ]
        );
        assert_eq!(
            hook_command(PATH.into()).unwrap(),
            "'/tmp/x y/powerup-hook.sh'"
        );
        assert!(hook_script_body(0, "t".into())
            .unwrap()
            .contains("http://127.0.0.1:1/event"));
        assert_eq!(
            hook_install_state(None, PATH.into(), None, 1, "t".into()).unwrap(),
            CoreHookInstallState::NotInstalled
        );
    }
}
