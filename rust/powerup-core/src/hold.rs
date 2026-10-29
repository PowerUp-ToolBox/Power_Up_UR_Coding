//! The hold rule (DESIGN v2.7 C): what a press or release on the active
//! controller does to the voice capture. Only the active controller can
//! start a hold, so there is no cross-device arbitration; ownership is the
//! control that started the hold.
//!
//! The state is a value the caller keeps and passes back in. Nothing here
//! knows about controller callbacks, the speech recognizer or haptics: the
//! OS app applies the effect it gets back.

use crate::action::Action;
use crate::intent::{intent_for, ControlPhase, Intent, VoiceCaptureMode};

/// The hold tracker's whole state: the control that started the running
/// hold, or `None` when the active controller owns no capture.
///
/// [`HoldState::step`] and [`HoldState::release_all`] clear the owner when
/// they end or cancel a capture. When a capture ends anywhere else (a toggle
/// stop, a denied speech permission, a vanished microphone), the caller must
/// replace its state with `HoldState::default()`, or a stale owner would
/// cancel the next capture (HK-032).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct HoldState {
    pub owner: Option<String>,
}

/// What one input does to the voice capture. Name for name with the Swift
/// app's `HoldEffect`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum HoldEffect {
    /// Start recording; the mode decides send-on-end or draft.
    BeginCapture(VoiceCaptureMode),
    /// The owner released: finish the capture normally.
    EndCapture,
    /// A second hold press while the controller owns a capture: the partial
    /// capture is discarded without sending or drafting.
    CancelCapture,
    /// A non-hold action fired: the caller hands its intent to the
    /// dispatcher.
    Deliver(Intent),
    /// Nothing to do: an unrelated release, a press with nothing to start,
    /// or a hold press during a capture the controller does not own.
    Ignore,
}

impl HoldEffect {
    /// The Swift case name (`beginCapture`, `endCapture`, `cancelCapture`,
    /// `deliver`, `ignore`), which the fixtures use.
    pub fn name(&self) -> &'static str {
        match self {
            HoldEffect::BeginCapture(_) => "beginCapture",
            HoldEffect::EndCapture => "endCapture",
            HoldEffect::CancelCapture => "cancelCapture",
            HoldEffect::Deliver(_) => "deliver",
            HoldEffect::Ignore => "ignore",
        }
    }
}

/// One input's outcome: the state to keep and the effect to apply.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HoldStep {
    pub state: HoldState,
    pub effect: HoldEffect,
}

impl HoldState {
    /// The effect of one input from the active controller.
    ///
    /// A release ends the capture only when `control_id` is the owner,
    /// whatever the control is mapped to now: a mapping edit mid-hold must
    /// not strand the recorder. Every other release, including both releases
    /// after a cancel, is ignored.
    ///
    /// A press of a non-hold action delivers its intent (or is ignored for
    /// [`Action::None`]) and leaves the owner alone. A hold press while the
    /// controller owns a capture cancels it and clears the owner, so neither
    /// control's later release can send the half sentence.
    /// `toggle_capture_active` says a capture started by a source with no
    /// press/release pair (the keyboard, the mic button) is running; the
    /// controller never owned it, so a hold press then is ignored rather
    /// than treated as a second hold. Otherwise a hold press begins a
    /// capture in the action's mode and records the control as the owner.
    pub fn step(
        &self,
        action: &Action,
        control_id: &str,
        phase: ControlPhase,
        toggle_capture_active: bool,
    ) -> HoldStep {
        match phase {
            ControlPhase::Ended => {
                if self.owner.as_deref() == Some(control_id) {
                    HoldStep::idle(HoldEffect::EndCapture)
                } else {
                    self.unchanged(HoldEffect::Ignore)
                }
            }
            ControlPhase::Began => {
                let Some(mode) = action.capture_mode() else {
                    let effect = intent_for(action, ControlPhase::Began)
                        .map_or(HoldEffect::Ignore, HoldEffect::Deliver);
                    return self.unchanged(effect);
                };
                if self.owner.is_some() {
                    HoldStep::idle(HoldEffect::CancelCapture)
                } else if toggle_capture_active {
                    self.unchanged(HoldEffect::Ignore)
                } else {
                    HoldStep {
                        state: HoldState {
                            owner: Some(control_id.to_owned()),
                        },
                        effect: HoldEffect::BeginCapture(mode),
                    }
                }
            }
        }
    }

    /// Ends a hold the controller owns when it can no longer be released
    /// normally: the controller disconnected, or the Controller slot
    /// changed. It ends, never cancels (HK-031): the user was still holding,
    /// so what they said is kept. A toggle-started capture is left alone.
    pub fn release_all(&self) -> HoldStep {
        if self.owner.is_some() {
            HoldStep::idle(HoldEffect::EndCapture)
        } else {
            self.unchanged(HoldEffect::Ignore)
        }
    }

    fn unchanged(&self, effect: HoldEffect) -> HoldStep {
        HoldStep {
            state: self.clone(),
            effect,
        }
    }
}

impl HoldStep {
    fn idle(effect: HoldEffect) -> HoldStep {
        HoldStep {
            state: HoldState::default(),
            effect,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift's `HoldEffect` cases in declaration order. The match has no
    /// wildcard, so a sixth variant fails to compile here until it is given
    /// a Swift name.
    #[test]
    fn effect_names_match_swift() {
        let every = [
            HoldEffect::BeginCapture(VoiceCaptureMode::Send),
            HoldEffect::EndCapture,
            HoldEffect::CancelCapture,
            HoldEffect::Deliver(Intent::Approve),
            HoldEffect::Ignore,
        ];
        for effect in &every {
            match effect {
                HoldEffect::BeginCapture(_)
                | HoldEffect::EndCapture
                | HoldEffect::CancelCapture
                | HoldEffect::Deliver(_)
                | HoldEffect::Ignore => {}
            }
        }
        assert_eq!(
            every.iter().map(HoldEffect::name).collect::<Vec<_>>(),
            [
                "beginCapture",
                "endCapture",
                "cancelCapture",
                "deliver",
                "ignore"
            ]
        );
    }

    #[test]
    fn a_step_never_mutates_the_state_it_was_given() {
        let idle = HoldState::default();
        let began = idle.step(&Action::PushToTalk, "r2", ControlPhase::Began, false);
        assert_eq!(idle, HoldState::default());
        assert_eq!(began.state.owner.as_deref(), Some("r2"));
    }
}
