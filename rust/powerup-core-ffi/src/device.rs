//! The device half of the device layer (slice 2.2): the Controller slot rule
//! and the hold rule.
//!
//! As in `mapping`, the types are the uniffi faces of their `powerup-core`
//! twins with a `Core` prefix (DESIGN v2.11 B), converted both ways with
//! exhaustive matches. The hold state is a value: Swift passes it in and
//! keeps the one that comes back, so the bridge holds no state of its own.

use powerup_core::hold::{HoldEffect, HoldState, HoldStep};
use powerup_core::slots::{self, ConnectedController};

use crate::mapping::{CoreAction, CoreControlPhase, CoreIntent, CoreVoiceCaptureMode};
use crate::{contain, CoreBridgeError};

/// A controller that is connected right now.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CoreConnectedController {
    pub id: String,
    pub profile_id: String,
    pub display_name: String,
}

/// The hold tracker's whole state: the control that owns the running hold.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CoreHoldState {
    pub owner: Option<String>,
}

/// What one input does to the voice capture, case for case with
/// `powerup_core::hold::HoldEffect`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreHoldEffect {
    BeginCapture { mode: CoreVoiceCaptureMode },
    EndCapture,
    CancelCapture,
    Deliver { intent: CoreIntent },
    Ignore,
}

/// One input's outcome: the state to keep and the effect to apply.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CoreHoldStep {
    pub state: CoreHoldState,
    pub effect: CoreHoldEffect,
}

impl From<ConnectedController> for CoreConnectedController {
    fn from(controller: ConnectedController) -> Self {
        CoreConnectedController {
            id: controller.id,
            profile_id: controller.profile_id,
            display_name: controller.display_name,
        }
    }
}

impl From<CoreConnectedController> for ConnectedController {
    fn from(controller: CoreConnectedController) -> Self {
        ConnectedController {
            id: controller.id,
            profile_id: controller.profile_id,
            display_name: controller.display_name,
        }
    }
}

impl From<HoldState> for CoreHoldState {
    fn from(state: HoldState) -> Self {
        CoreHoldState { owner: state.owner }
    }
}

impl From<CoreHoldState> for HoldState {
    fn from(state: CoreHoldState) -> Self {
        HoldState { owner: state.owner }
    }
}

impl From<HoldEffect> for CoreHoldEffect {
    fn from(effect: HoldEffect) -> Self {
        match effect {
            HoldEffect::BeginCapture(mode) => CoreHoldEffect::BeginCapture { mode: mode.into() },
            HoldEffect::EndCapture => CoreHoldEffect::EndCapture,
            HoldEffect::CancelCapture => CoreHoldEffect::CancelCapture,
            HoldEffect::Deliver(intent) => CoreHoldEffect::Deliver {
                intent: intent.into(),
            },
            HoldEffect::Ignore => CoreHoldEffect::Ignore,
        }
    }
}

impl From<CoreHoldEffect> for HoldEffect {
    fn from(effect: CoreHoldEffect) -> Self {
        match effect {
            CoreHoldEffect::BeginCapture { mode } => HoldEffect::BeginCapture(mode.into()),
            CoreHoldEffect::EndCapture => HoldEffect::EndCapture,
            CoreHoldEffect::CancelCapture => HoldEffect::CancelCapture,
            CoreHoldEffect::Deliver { intent } => HoldEffect::Deliver(intent.into()),
            CoreHoldEffect::Ignore => HoldEffect::Ignore,
        }
    }
}

impl From<HoldStep> for CoreHoldStep {
    fn from(step: HoldStep) -> Self {
        CoreHoldStep {
            state: step.state.into(),
            effect: step.effect.into(),
        }
    }
}

/// The controller that fills the Controller slot, or none when it is empty
/// (`slots::select_active_controller`; HK-016, HK-017).
#[uniffi::export]
pub fn select_active_controller(
    most_recently_connected_first: Vec<CoreConnectedController>,
    pinned_id: Option<String>,
) -> Result<Option<CoreConnectedController>, CoreBridgeError> {
    contain(|| {
        let connected: Vec<ConnectedController> = most_recently_connected_first
            .into_iter()
            .map(Into::into)
            .collect();
        Ok(
            slots::select_active_controller(&connected, pinned_id.as_deref())
                .cloned()
                .map(Into::into),
        )
    })
}

/// The effect of one input from the active controller, and the state to keep
/// (`hold::HoldState::step`).
#[uniffi::export]
pub fn hold_tracker_step(
    state: CoreHoldState,
    action: CoreAction,
    control_id: String,
    phase: CoreControlPhase,
    toggle_capture_active: bool,
) -> Result<CoreHoldStep, CoreBridgeError> {
    contain(|| {
        let state = HoldState::from(state);
        Ok(state
            .step(
                &action.into(),
                &control_id,
                phase.into(),
                toggle_capture_active,
            )
            .into())
    })
}

/// Ends a hold the active controller owns when it can no longer be released
/// normally (`hold::HoldState::release_all`).
#[uniffi::export]
pub fn hold_tracker_release_all(state: CoreHoldState) -> Result<CoreHoldStep, CoreBridgeError> {
    contain(|| Ok(HoldState::from(state).release_all().into()))
}

#[cfg(test)]
mod tests {
    use powerup_core::intent::{Intent, VoiceCaptureMode};

    use super::*;

    #[test]
    fn every_effect_round_trips_through_the_bridge_type() {
        let every = [
            HoldEffect::BeginCapture(VoiceCaptureMode::Send),
            HoldEffect::BeginCapture(VoiceCaptureMode::Draft),
            HoldEffect::EndCapture,
            HoldEffect::CancelCapture,
            HoldEffect::Deliver(Intent::SendPrompt("Continue".to_string())),
            HoldEffect::Ignore,
        ];
        for effect in every {
            assert_eq!(
                HoldEffect::from(CoreHoldEffect::from(effect.clone())),
                effect
            );
        }
        for owner in [None, Some("r2".to_string())] {
            let state = HoldState { owner };
            assert_eq!(HoldState::from(CoreHoldState::from(state.clone())), state);
        }
        let controller = ConnectedController {
            id: "pad-1".to_string(),
            profile_id: "dualsense".to_string(),
            display_name: "DualSense".to_string(),
        };
        assert_eq!(
            ConnectedController::from(CoreConnectedController::from(controller.clone())),
            controller
        );
    }

    fn pad(id: &str, name: &str) -> CoreConnectedController {
        CoreConnectedController {
            id: id.to_string(),
            profile_id: "dualsense".to_string(),
            display_name: name.to_string(),
        }
    }

    #[test]
    fn the_slot_rule_answers_like_the_core() {
        let connected = vec![
            pad("couch", "Couch"),
            pad("desk", "Desk"),
            pad("desk", "Twin"),
        ];
        let select = |pin: Option<&str>| {
            select_active_controller(connected.clone(), pin.map(str::to_string))
        };
        assert_eq!(select(None), Ok(Some(pad("couch", "Couch"))));
        assert_eq!(select(Some("desk")), Ok(Some(pad("desk", "Desk"))));
        assert_eq!(select(Some("gone")), Ok(None));
        assert_eq!(select(Some("")), Ok(None));
        assert_eq!(select_active_controller(Vec::new(), None), Ok(None));
    }

    #[test]
    fn the_hold_rule_answers_like_the_core() {
        let idle = CoreHoldState::default();
        let began = hold_tracker_step(
            idle.clone(),
            CoreAction::PushToTalkDraft,
            "r2".to_string(),
            CoreControlPhase::Began,
            false,
        );
        let owned = CoreHoldState {
            owner: Some("r2".to_string()),
        };
        assert_eq!(
            began,
            Ok(CoreHoldStep {
                state: owned.clone(),
                effect: CoreHoldEffect::BeginCapture {
                    mode: CoreVoiceCaptureMode::Draft
                },
            })
        );
        assert_eq!(
            hold_tracker_step(
                owned.clone(),
                CoreAction::Approve,
                "cross".to_string(),
                CoreControlPhase::Began,
                false,
            ),
            Ok(CoreHoldStep {
                state: owned.clone(),
                effect: CoreHoldEffect::Deliver {
                    intent: CoreIntent::Approve
                },
            })
        );
        assert_eq!(
            hold_tracker_step(
                owned.clone(),
                CoreAction::PushToTalk,
                "l2".to_string(),
                CoreControlPhase::Began,
                false,
            ),
            Ok(CoreHoldStep {
                state: idle.clone(),
                effect: CoreHoldEffect::CancelCapture,
            })
        );
        assert_eq!(
            hold_tracker_release_all(owned),
            Ok(CoreHoldStep {
                state: idle.clone(),
                effect: CoreHoldEffect::EndCapture,
            })
        );
        assert_eq!(
            hold_tracker_release_all(idle.clone()),
            Ok(CoreHoldStep {
                state: idle,
                effect: CoreHoldEffect::Ignore,
            })
        );
    }
}
