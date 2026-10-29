//! The intent vocabulary (DESIGN v2.7 A): what any input source, a mapped
//! control or a protocol client, asks the app to do. It is deliberately
//! distinct from [`Action`], the mapping vocabulary stored per control: a hold
//! action becomes a begin/end intent pair, and a source with no controls can
//! send intents without any mapping existing.

use crate::action::Action;

/// What the active voice capture does when it ends: send the transcript to
/// the harness, or drop it into the prompt box for review.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VoiceCaptureMode {
    Send,
    Draft,
}

impl VoiceCaptureMode {
    /// The Swift case name (`send`, `draft`), which the fixtures use.
    pub fn name(self) -> &'static str {
        match self {
            VoiceCaptureMode::Send => "send",
            VoiceCaptureMode::Draft => "draft",
        }
    }
}

/// Whether a physical control is being pressed or released.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ControlPhase {
    Began,
    Ended,
}

/// One user intent. The variants match Swift's `Intent` case for case.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Intent {
    BeginVoiceCapture(VoiceCaptureMode),
    EndVoiceCapture,
    SendPrompt(String),
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

impl Intent {
    /// The Swift case name (`toggleTTS`, `beginVoiceCapture`, …). The
    /// fixtures name intents this way, and so do protocol clients for the
    /// intents they may send.
    pub fn name(&self) -> &'static str {
        match self {
            Intent::BeginVoiceCapture(_) => "beginVoiceCapture",
            Intent::EndVoiceCapture => "endVoiceCapture",
            Intent::SendPrompt(_) => "sendPrompt",
            Intent::SendDraft => "sendDraft",
            Intent::Approve => "approve",
            Intent::Reject => "reject",
            Intent::Interrupt => "interrupt",
            Intent::StopSpeaking => "stopSpeaking",
            Intent::ReplayLastReply => "replayLastReply",
            Intent::ToggleTts => "toggleTTS",
            Intent::NewSession => "newSession",
            Intent::ShowWindow => "showWindow",
            Intent::CycleModel => "cycleModel",
            Intent::CycleEffort => "cycleEffort",
            Intent::CyclePermissionMode => "cyclePermissionMode",
            Intent::CycleProject => "cycleProject",
            Intent::CycleFocus => "cycleFocus",
            Intent::ToggleControlMode => "toggleControlMode",
        }
    }
}

/// The intent a mapped action produces for a press or a release.
///
/// Stateless by design (HK-033): the one-hold-at-a-time bookkeeping belongs
/// to the caller, which knows which physical control a capture belongs to. A
/// hold action gives a begin/end pair; every other action fires on the press
/// and gives `None` on the release; [`Action::None`] gives `None` for both.
pub fn intent_for(action: &Action, phase: ControlPhase) -> Option<Intent> {
    match phase {
        ControlPhase::Ended => action.is_hold().then_some(Intent::EndVoiceCapture),
        ControlPhase::Began => match action {
            Action::None => None,
            Action::PushToTalk => Some(Intent::BeginVoiceCapture(VoiceCaptureMode::Send)),
            Action::PushToTalkDraft => Some(Intent::BeginVoiceCapture(VoiceCaptureMode::Draft)),
            Action::SendPrompt(prompt) => Some(Intent::SendPrompt(prompt.clone())),
            Action::SendDraft => Some(Intent::SendDraft),
            Action::Approve => Some(Intent::Approve),
            Action::Reject => Some(Intent::Reject),
            Action::Interrupt => Some(Intent::Interrupt),
            Action::StopSpeaking => Some(Intent::StopSpeaking),
            Action::ReplayLastReply => Some(Intent::ReplayLastReply),
            Action::ToggleTts => Some(Intent::ToggleTts),
            Action::NewSession => Some(Intent::NewSession),
            Action::ShowWindow => Some(Intent::ShowWindow),
            Action::CycleModel => Some(Intent::CycleModel),
            Action::CycleEffort => Some(Intent::CycleEffort),
            Action::CyclePermissionMode => Some(Intent::CyclePermissionMode),
            Action::CycleProject => Some(Intent::CycleProject),
            Action::CycleFocus => Some(Intent::CycleFocus),
            Action::ToggleControlMode => Some(Intent::ToggleControlMode),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hold_action_ends_its_capture_on_release_whatever_its_mode() {
        for action in [Action::PushToTalk, Action::PushToTalkDraft] {
            assert_eq!(
                intent_for(&action, ControlPhase::Ended),
                Some(Intent::EndVoiceCapture)
            );
        }
        assert_eq!(intent_for(&Action::Approve, ControlPhase::Ended), None);
    }
}
