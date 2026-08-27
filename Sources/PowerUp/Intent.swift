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
/// This is deliberately distinct from `ControllerAction` (the *mapping*
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
    case toggleControlMode
}

// MARK: - IntentMapper

/// Whether a physical control is being pressed or released.
enum ControlPhase: Equatable {
    case began, ended
}

/// Pure translation from mapping vocabulary (and from protocol wire names)
/// into intents. Stateless by design — the "one hold at a time" bookkeeping
/// stays with the caller, which knows which physical control it belongs to.
enum IntentMapper {

    /// The intent a mapped action produces for a press (`.began`) or release
    /// (`.ended`). Non-hold actions fire on the press and return nil for the
    /// release; hold actions return the begin/end pair.
    static func intent(for action: ControllerAction, phase: ControlPhase) -> Intent? {
        switch phase {
        case .ended:
            return action.isHoldAction ? .endVoiceCapture : nil
        case .began:
            switch action {
            case .none: return nil
            case .pushToTalk: return .beginVoiceCapture(.send)
            case .pushToTalkDraft: return .beginVoiceCapture(.draft)
            case .sendPrompt(let prompt): return .sendPrompt(prompt)
            case .sendDraft: return .sendDraft
            case .approve: return .approve
            case .reject: return .reject
            case .interrupt: return .interrupt
            case .stopSpeaking: return .stopSpeaking
            case .replayLastReply: return .replayLastReply
            case .toggleTTS: return .toggleTTS
            case .newSession: return .newSession
            case .showWindow: return .showWindow
            case .cycleModel: return .cycleModel
            case .cycleEffort: return .cycleEffort
            case .cyclePermissionMode: return .cyclePermissionMode
            case .cycleProject: return .cycleProject
            case .toggleControlMode: return .toggleControlMode
            }
        }
    }

    /// The intents a *protocol client* may send, by wire name (see
    /// docs/protocol.md). Deliberately a subset:
    /// - No voice-capture intents — the microphone is local to the app; remote
    ///   clients send text via `sendPrompt` instead.
    /// - No name grants anything the controller can't already do: permission
    ///   mode is only reachable via `cyclePermissionMode`, whose fixed cycle
    ///   excludes `bypassPermissions` (see AppConfig.permissionModeCycle) —
    ///   the protocol can never escalate to auto-approve-everything.
    /// Unknown names return nil; the server answers those with an error
    /// message, never by acting.
    static func intent(forProtocolName name: String, text: String?) -> Intent? {
        switch name {
        case "sendPrompt":
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .sendPrompt(text)
        case "sendDraft": return .sendDraft
        case "approve": return .approve
        case "reject": return .reject
        case "interrupt": return .interrupt
        case "stopSpeaking": return .stopSpeaking
        case "replayLastReply": return .replayLastReply
        case "toggleTTS": return .toggleTTS
        case "newSession": return .newSession
        case "showWindow": return .showWindow
        case "cycleModel": return .cycleModel
        case "cycleEffort": return .cycleEffort
        case "cyclePermissionMode": return .cyclePermissionMode
        case "cycleProject": return .cycleProject
        case "toggleControlMode": return .toggleControlMode
        default: return nil
        }
    }
}
