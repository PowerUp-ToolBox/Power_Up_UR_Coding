//! The mapping half of the device layer (slice 2.2): the intent rule, the
//! hold flag, an action's wire bytes, action resolution, the default
//! mappings, the control-kind rule and the built-in DualSense profile. The
//! config mapping subtree crosses inside the whole config since slice 2.5
//! (`config`).
//!
//! The types here are the uniffi faces of their `powerup-core` twins and
//! carry a `Core` prefix, so they never collide with the Swift app's own
//! `Action` or `Intent` (DESIGN v2.11 B). Each converts both ways with an
//! exhaustive match, so a variant added on one side is a compile error here.

use std::collections::HashMap;

use powerup_core::action::Action;
use powerup_core::intent::{intent_for, ControlPhase, Intent, VoiceCaptureMode};
use powerup_core::mapping::{self, DeviceMappings};
use powerup_core::profile::{self, ControlDescriptor, ControlKind, DeviceProfile};

use crate::{contain, CoreBridgeError};

/// One mapped action, case for case with `powerup_core::action::Action`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreAction {
    None,
    PushToTalk,
    SendPrompt { prompt: String },
    Approve,
    Reject,
    Interrupt,
    StopSpeaking,
    ReplayLastReply,
    ToggleTts,
    NewSession,
    ShowWindow,
    CycleModel,
    CycleEffort,
    CyclePermissionMode,
    CycleProject,
    CycleFocus,
    PushToTalkDraft,
    SendDraft,
    ToggleControlMode,
}

/// What a voice capture does when it ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreVoiceCaptureMode {
    Send,
    Draft,
}

/// Whether a control is being pressed or released.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreControlPhase {
    Began,
    Ended,
}

/// One user intent, case for case with `powerup_core::intent::Intent`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreIntent {
    BeginVoiceCapture { mode: CoreVoiceCaptureMode },
    EndVoiceCapture,
    SendPrompt { prompt: String },
    SendDraft,
    Approve,
    Reject,
    Interrupt,
    StopSpeaking,
    ReplayLastReply,
    ToggleTts,
    NewSession,
    ShowWindow,
    CycleModel,
    CycleEffort,
    CyclePermissionMode,
    CycleProject,
    CycleFocus,
    ToggleControlMode,
}

/// What a control is physically.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreControlKind {
    Button,
    Axis,
    Key,
}

/// One control on a device.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CoreControlDescriptor {
    pub id: String,
    pub kind: CoreControlKind,
    pub display_name: String,
    pub symbol_name: String,
}

/// A device: its id, its name and its controls in order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreDeviceProfile {
    pub id: String,
    pub display_name: String,
    pub controls: Vec<CoreControlDescriptor>,
}

/// Profile id → (control id → action), as uniffi carries it.
pub type CoreDeviceMappings = HashMap<String, HashMap<String, CoreAction>>;

impl From<Action> for CoreAction {
    fn from(action: Action) -> Self {
        match action {
            Action::None => CoreAction::None,
            Action::PushToTalk => CoreAction::PushToTalk,
            Action::SendPrompt(prompt) => CoreAction::SendPrompt { prompt },
            Action::Approve => CoreAction::Approve,
            Action::Reject => CoreAction::Reject,
            Action::Interrupt => CoreAction::Interrupt,
            Action::StopSpeaking => CoreAction::StopSpeaking,
            Action::ReplayLastReply => CoreAction::ReplayLastReply,
            Action::ToggleTts => CoreAction::ToggleTts,
            Action::NewSession => CoreAction::NewSession,
            Action::ShowWindow => CoreAction::ShowWindow,
            Action::CycleModel => CoreAction::CycleModel,
            Action::CycleEffort => CoreAction::CycleEffort,
            Action::CyclePermissionMode => CoreAction::CyclePermissionMode,
            Action::CycleProject => CoreAction::CycleProject,
            Action::CycleFocus => CoreAction::CycleFocus,
            Action::PushToTalkDraft => CoreAction::PushToTalkDraft,
            Action::SendDraft => CoreAction::SendDraft,
            Action::ToggleControlMode => CoreAction::ToggleControlMode,
        }
    }
}

impl From<CoreAction> for Action {
    fn from(action: CoreAction) -> Self {
        match action {
            CoreAction::None => Action::None,
            CoreAction::PushToTalk => Action::PushToTalk,
            CoreAction::SendPrompt { prompt } => Action::SendPrompt(prompt),
            CoreAction::Approve => Action::Approve,
            CoreAction::Reject => Action::Reject,
            CoreAction::Interrupt => Action::Interrupt,
            CoreAction::StopSpeaking => Action::StopSpeaking,
            CoreAction::ReplayLastReply => Action::ReplayLastReply,
            CoreAction::ToggleTts => Action::ToggleTts,
            CoreAction::NewSession => Action::NewSession,
            CoreAction::ShowWindow => Action::ShowWindow,
            CoreAction::CycleModel => Action::CycleModel,
            CoreAction::CycleEffort => Action::CycleEffort,
            CoreAction::CyclePermissionMode => Action::CyclePermissionMode,
            CoreAction::CycleProject => Action::CycleProject,
            CoreAction::CycleFocus => Action::CycleFocus,
            CoreAction::PushToTalkDraft => Action::PushToTalkDraft,
            CoreAction::SendDraft => Action::SendDraft,
            CoreAction::ToggleControlMode => Action::ToggleControlMode,
        }
    }
}

impl From<VoiceCaptureMode> for CoreVoiceCaptureMode {
    fn from(mode: VoiceCaptureMode) -> Self {
        match mode {
            VoiceCaptureMode::Send => CoreVoiceCaptureMode::Send,
            VoiceCaptureMode::Draft => CoreVoiceCaptureMode::Draft,
        }
    }
}

impl From<CoreVoiceCaptureMode> for VoiceCaptureMode {
    fn from(mode: CoreVoiceCaptureMode) -> Self {
        match mode {
            CoreVoiceCaptureMode::Send => VoiceCaptureMode::Send,
            CoreVoiceCaptureMode::Draft => VoiceCaptureMode::Draft,
        }
    }
}

impl From<ControlPhase> for CoreControlPhase {
    fn from(phase: ControlPhase) -> Self {
        match phase {
            ControlPhase::Began => CoreControlPhase::Began,
            ControlPhase::Ended => CoreControlPhase::Ended,
        }
    }
}

impl From<CoreControlPhase> for ControlPhase {
    fn from(phase: CoreControlPhase) -> Self {
        match phase {
            CoreControlPhase::Began => ControlPhase::Began,
            CoreControlPhase::Ended => ControlPhase::Ended,
        }
    }
}

impl From<Intent> for CoreIntent {
    fn from(intent: Intent) -> Self {
        match intent {
            Intent::BeginVoiceCapture(mode) => CoreIntent::BeginVoiceCapture { mode: mode.into() },
            Intent::EndVoiceCapture => CoreIntent::EndVoiceCapture,
            Intent::SendPrompt(prompt) => CoreIntent::SendPrompt { prompt },
            Intent::SendDraft => CoreIntent::SendDraft,
            Intent::Approve => CoreIntent::Approve,
            Intent::Reject => CoreIntent::Reject,
            Intent::Interrupt => CoreIntent::Interrupt,
            Intent::StopSpeaking => CoreIntent::StopSpeaking,
            Intent::ReplayLastReply => CoreIntent::ReplayLastReply,
            Intent::ToggleTts => CoreIntent::ToggleTts,
            Intent::NewSession => CoreIntent::NewSession,
            Intent::ShowWindow => CoreIntent::ShowWindow,
            Intent::CycleModel => CoreIntent::CycleModel,
            Intent::CycleEffort => CoreIntent::CycleEffort,
            Intent::CyclePermissionMode => CoreIntent::CyclePermissionMode,
            Intent::CycleProject => CoreIntent::CycleProject,
            Intent::CycleFocus => CoreIntent::CycleFocus,
            Intent::ToggleControlMode => CoreIntent::ToggleControlMode,
        }
    }
}

impl From<CoreIntent> for Intent {
    fn from(intent: CoreIntent) -> Self {
        match intent {
            CoreIntent::BeginVoiceCapture { mode } => Intent::BeginVoiceCapture(mode.into()),
            CoreIntent::EndVoiceCapture => Intent::EndVoiceCapture,
            CoreIntent::SendPrompt { prompt } => Intent::SendPrompt(prompt),
            CoreIntent::SendDraft => Intent::SendDraft,
            CoreIntent::Approve => Intent::Approve,
            CoreIntent::Reject => Intent::Reject,
            CoreIntent::Interrupt => Intent::Interrupt,
            CoreIntent::StopSpeaking => Intent::StopSpeaking,
            CoreIntent::ReplayLastReply => Intent::ReplayLastReply,
            CoreIntent::ToggleTts => Intent::ToggleTts,
            CoreIntent::NewSession => Intent::NewSession,
            CoreIntent::ShowWindow => Intent::ShowWindow,
            CoreIntent::CycleModel => Intent::CycleModel,
            CoreIntent::CycleEffort => Intent::CycleEffort,
            CoreIntent::CyclePermissionMode => Intent::CyclePermissionMode,
            CoreIntent::CycleProject => Intent::CycleProject,
            CoreIntent::CycleFocus => Intent::CycleFocus,
            CoreIntent::ToggleControlMode => Intent::ToggleControlMode,
        }
    }
}

impl From<ControlKind> for CoreControlKind {
    fn from(kind: ControlKind) -> Self {
        match kind {
            ControlKind::Button => CoreControlKind::Button,
            ControlKind::Axis => CoreControlKind::Axis,
            ControlKind::Key => CoreControlKind::Key,
        }
    }
}

impl From<CoreControlKind> for ControlKind {
    fn from(kind: CoreControlKind) -> Self {
        match kind {
            CoreControlKind::Button => ControlKind::Button,
            CoreControlKind::Axis => ControlKind::Axis,
            CoreControlKind::Key => ControlKind::Key,
        }
    }
}

impl From<ControlDescriptor> for CoreControlDescriptor {
    fn from(control: ControlDescriptor) -> Self {
        CoreControlDescriptor {
            id: control.id,
            kind: control.kind.into(),
            display_name: control.display_name,
            symbol_name: control.symbol_name,
        }
    }
}

impl From<CoreControlDescriptor> for ControlDescriptor {
    fn from(control: CoreControlDescriptor) -> Self {
        ControlDescriptor {
            id: control.id,
            kind: control.kind.into(),
            display_name: control.display_name,
            symbol_name: control.symbol_name,
        }
    }
}

impl From<DeviceProfile> for CoreDeviceProfile {
    fn from(profile: DeviceProfile) -> Self {
        CoreDeviceProfile {
            id: profile.id,
            display_name: profile.display_name,
            controls: profile.controls.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<CoreDeviceProfile> for DeviceProfile {
    fn from(profile: CoreDeviceProfile) -> Self {
        DeviceProfile {
            id: profile.id,
            display_name: profile.display_name,
            controls: profile.controls.into_iter().map(Into::into).collect(),
        }
    }
}

pub(crate) fn to_bridge_mappings(mappings: DeviceMappings) -> CoreDeviceMappings {
    mappings
        .into_iter()
        .map(|(profile, controls)| {
            let controls = controls
                .into_iter()
                .map(|(control, action)| (control, action.into()))
                .collect();
            (profile, controls)
        })
        .collect()
}

pub(crate) fn to_core_mappings(mappings: CoreDeviceMappings) -> DeviceMappings {
    mappings
        .into_iter()
        .map(|(profile, controls)| {
            let controls = controls
                .into_iter()
                .map(|(control, action)| (control, action.into()))
                .collect();
            (profile, controls)
        })
        .collect()
}

/// The intent `action` produces for a press or a release (`intent::intent_for`).
#[uniffi::export]
pub fn intent_for_action(
    action: CoreAction,
    phase: CoreControlPhase,
) -> Result<Option<CoreIntent>, CoreBridgeError> {
    contain(|| Ok(intent_for(&action.into(), phase.into()).map(Into::into)))
}

/// Whether `action` records while held and finishes on release (HK-004).
#[uniffi::export]
pub fn action_is_hold(action: CoreAction) -> Result<bool, CoreBridgeError> {
    contain(|| Ok(Action::from(action).is_hold()))
}

/// The compact JSON `action` is stored as, byte for byte what Swift's
/// `JSONEncoder` with `.sortedKeys` writes.
#[uniffi::export]
pub fn action_wire_json(action: CoreAction) -> Result<String, CoreBridgeError> {
    contain(|| Action::from(action).to_wire_json())
}

/// The action mapped to (profile, control); `none` when unmapped (DESIGN v2.4 B).
#[uniffi::export]
pub fn resolve_action(
    device_mappings: CoreDeviceMappings,
    profile_id: String,
    control_id: String,
) -> Result<CoreAction, CoreBridgeError> {
    contain(|| {
        let mappings = to_core_mappings(device_mappings);
        Ok(mapping::resolve_action(&mappings, &profile_id, &control_id).into())
    })
}

/// The shipped mappings: the DualSense profile with the default layout.
#[uniffi::export]
pub fn default_device_mappings() -> Result<CoreDeviceMappings, CoreBridgeError> {
    contain(|| Ok(to_bridge_mappings(mapping::default_device_mappings())))
}

/// The kind a profile file's string reads as; the pre-v2.7 `hold` reads as a
/// button (HK-005), and anything else is no kind.
#[uniffi::export]
pub fn control_kind_from_wire(name: String) -> Result<Option<CoreControlKind>, CoreBridgeError> {
    contain(|| Ok(ControlKind::from_wire(&name).map(Into::into)))
}

/// The built-in DualSense profile, controls in `ControllerButton.allCases` order.
#[uniffi::export]
pub fn dualsense_profile() -> Result<CoreDeviceProfile, CoreBridgeError> {
    contain(|| Ok(profile::dualsense_profile().into()))
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    fn every_action() -> Vec<Action> {
        vec![
            Action::None,
            Action::PushToTalk,
            Action::SendPrompt("Continue".to_string()),
            Action::Approve,
            Action::Reject,
            Action::Interrupt,
            Action::StopSpeaking,
            Action::ReplayLastReply,
            Action::ToggleTts,
            Action::NewSession,
            Action::ShowWindow,
            Action::CycleModel,
            Action::CycleEffort,
            Action::CyclePermissionMode,
            Action::CycleProject,
            Action::CycleFocus,
            Action::PushToTalkDraft,
            Action::SendDraft,
            Action::ToggleControlMode,
        ]
    }

    #[test]
    fn every_action_round_trips_through_the_bridge_type() {
        let actions = every_action();
        assert_eq!(actions.len(), powerup_core::action::WIRE_NAMES.len());
        for action in actions {
            let bridged = CoreAction::from(action.clone());
            assert_eq!(Action::from(bridged), action);
        }
    }

    #[test]
    fn every_intent_round_trips_through_the_bridge_type() {
        let intents: HashSet<Intent> = every_action()
            .iter()
            .flat_map(|action| {
                [ControlPhase::Began, ControlPhase::Ended]
                    .into_iter()
                    .filter_map(move |phase| intent_for(action, phase))
            })
            .collect();
        // Every intent value a mapping can produce: one per press of the 18
        // actions other than none (the two holds give the two begins), plus
        // endVoiceCapture from their releases.
        assert_eq!(intents.len(), 19);
        for intent in intents {
            let bridged = CoreIntent::from(intent.clone());
            assert_eq!(Intent::from(bridged), intent);
        }
    }

    #[test]
    fn every_kind_and_phase_round_trips_through_the_bridge_type() {
        for kind in [ControlKind::Button, ControlKind::Axis, ControlKind::Key] {
            assert_eq!(ControlKind::from(CoreControlKind::from(kind)), kind);
        }
        for phase in [ControlPhase::Began, ControlPhase::Ended] {
            assert_eq!(ControlPhase::from(CoreControlPhase::from(phase)), phase);
        }
        let profile = profile::dualsense_profile();
        assert_eq!(
            DeviceProfile::from(CoreDeviceProfile::from(profile.clone())),
            profile
        );
    }

    #[test]
    fn the_bridge_answers_like_the_core() {
        assert_eq!(
            intent_for_action(CoreAction::PushToTalkDraft, CoreControlPhase::Began),
            Ok(Some(CoreIntent::BeginVoiceCapture {
                mode: CoreVoiceCaptureMode::Draft
            }))
        );
        assert_eq!(
            intent_for_action(CoreAction::Approve, CoreControlPhase::Ended),
            Ok(None)
        );
        assert_eq!(action_is_hold(CoreAction::PushToTalk), Ok(true));
        assert_eq!(action_is_hold(CoreAction::SendDraft), Ok(false));
        assert_eq!(
            action_wire_json(CoreAction::SendPrompt {
                prompt: "Run tests/unit".to_string()
            }),
            Ok(r#"{"sendPrompt":{"_0":"Run tests\/unit"}}"#.to_string())
        );
        assert_eq!(
            control_kind_from_wire("hold".to_string()),
            Ok(Some(CoreControlKind::Button))
        );
        assert_eq!(control_kind_from_wire("Button".to_string()), Ok(None));
        let defaults = default_device_mappings();
        assert_eq!(
            defaults
                .as_ref()
                .map(|mappings| mappings["dualsense"]["r2"].clone()),
            Ok(CoreAction::PushToTalk)
        );
    }

    #[test]
    fn resolve_action_returns_none_when_unmapped() {
        let mappings = default_device_mappings().unwrap_or_default();
        let resolve = |profile: &str, control: &str| {
            resolve_action(mappings.clone(), profile.to_string(), control.to_string())
        };
        assert_eq!(resolve("dualsense", "cross"), Ok(CoreAction::Approve));
        assert_eq!(resolve("dualsense", "pedal"), Ok(CoreAction::None));
        assert_eq!(resolve("streamdeck", "cross"), Ok(CoreAction::None));
    }
}
