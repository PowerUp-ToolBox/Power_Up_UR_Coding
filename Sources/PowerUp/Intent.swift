import Foundation

// MARK: - Intent

/// What the active voice capture does when it ends: send the transcript
/// straight to the harness, or drop it into the prompt box for review.
enum VoiceCaptureMode: String, Equatable {
    case send, draft
}

/// The device-agnostic vocabulary of user actions — what flows from any input
/// source (the DualSense today; headsets, pedals, macropads, and protocol
/// clients tomorrow) into `AppState`'s dispatcher.
///
/// This is deliberately distinct from `Action` (the *mapping*
/// vocabulary stored per button in the config): a hold-style action like
/// `.pushToTalk` becomes a begin/end intent *pair*, and a source that has no
/// buttons at all (a protocol client) can emit intents directly without any
/// mapping existing.
enum Intent: Equatable {
    case beginVoiceCapture(VoiceCaptureMode)
    case endVoiceCapture
    case sendPrompt(String)
    case sendDraft
    case approve
    case reject
    case interrupt
    case stopSpeaking
    case replayLastReply
    case toggleTTS
    case newSession
    case showWindow
    case cycleModel
    case cycleEffort
    case cyclePermissionMode
    case cycleProject
    case cycleFocus
    case toggleControlMode
}

// MARK: - IntentMapper

/// Whether a physical control is being pressed or released.
enum ControlPhase: Equatable {
    case began, ended
}

/// Pure translation from mapping vocabulary (through the Rust core) into
/// intents. Stateless by design — the "one hold at a time" bookkeeping stays
/// with the caller, which knows which physical control it belongs to. The
/// protocol's wire names are the core's name table since slice 2.6
/// (`CoreBridge.protocolIntent(name:text:)`).
enum IntentMapper {

    /// The intent a mapped action produces for a press (`.began`) or release
    /// (`.ended`). Non-hold actions fire on the press and return nil for the
    /// release; hold actions return the begin/end pair. The rule lives in the
    /// Rust core (`powerup-core` `intent::intent_for`, slice 2.2).
    static func intent(for action: Action, phase: ControlPhase) -> Intent? {
        CoreBridge.intent(for: action, phase: phase)
    }
}
