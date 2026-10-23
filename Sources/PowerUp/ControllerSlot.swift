/// A controller that is connected right now, as PowerUp sees it.
///
/// Pure data on purpose: the Controller slot rule is decided from a list of
/// these, with no controller-framework types. `ControllerService`
/// publishes the ordered list and the one active controller (DESIGN.md v2.7
/// addendum §B).
struct ConnectedController: Identifiable, Equatable {
    /// Stable for the life of one connection; what a pin stores.
    let id: String
    /// The profile describing this kind of controller, e.g. "dualsense".
    let profileID: String
    /// What the Settings picker shows.
    let displayName: String
}

/// Decides which connected controller fills the Controller slot.
///
/// A pure value type (CONTEXT.md: Slot, Controller; ADR 0013; DESIGN.md v2.7
/// addendum §B): the connected controllers in connection order and the pinned
/// id go in, the controller in the slot comes out. The order is the input
/// list's own order — spelled out in the parameter label so a caller cannot
/// pass a differently ordered list and get a plausible wrong answer — never a
/// framework callback's arrival order, and nothing here is observable or
/// mutable.
struct ControllerSlotSelector: Equatable {
    /// The connected controllers, most recently connected first.
    let mostRecentlyConnectedFirst: [ConnectedController]
    /// The pinned Controller device id; `nil` means Automatic.
    let pinnedID: String?

    /// The controller that fills the slot, or `nil` when the slot is empty.
    ///
    /// Automatic (`pinnedID == nil`) takes the head of the list — the most
    /// recent connection — so losing it hands the slot to the next most
    /// recent. A pin holds the slot only while that controller is connected:
    /// while it is away the slot stays empty rather than falling back to
    /// Automatic, and its return takes the slot back with no new pinning.
    var active: ConnectedController? {
        guard let pinnedID else { return mostRecentlyConnectedFirst.first }
        return mostRecentlyConnectedFirst.first { $0.id == pinnedID }
    }
}

// MARK: - Hold

/// What one input on the active controller does to the voice capture
/// (DESIGN.md v2.7 addendum §C). Plain data: the AppState adapter switches on
/// it, and it is one of the five effects the Rust core will return.
enum HoldEffect: Equatable {
    /// Start recording; the action's mode decides send-on-end or draft.
    case beginCapture(VoiceCaptureMode)
    /// The owner released: finish the capture normally.
    case endCapture
    /// A second hold press on the active controller: the partial capture is
    /// discarded without sending or drafting, and the pad pulses the error
    /// haptic.
    case cancelCapture
    /// A non-hold action fired: hand its intent to the existing dispatcher.
    case deliver(Intent)
    /// Nothing to do: an unrelated release, a press with nothing to start, or
    /// a press during a capture the active controller does not own.
    case ignore
}

/// Tracks which control on the active controller owns the running hold.
///
/// A pure value type (CONTEXT.md: Hold, Action, Control; DESIGN.md v2.7
/// addendum §C). The action, the control id, the phase and whether a
/// toggle-started capture is running go in; one `HoldEffect` per input comes
/// out, alongside the owner this tracker keeps. Nothing here knows about
/// framework callbacks, the recognizer or haptics — the AppState adapter does.
struct HoldTracker: Equatable {
    /// The control id that started the running hold, or `nil` when the active
    /// controller owns no capture. Cleared by the owner's release and by a
    /// cancel. When a capture ends anywhere else (a toggle, a denied speech
    /// permission — everywhere `pttHoldButton = nil` is set today), the
    /// adapter must replace the tracker with a fresh `HoldTracker()`, or a
    /// stale owner would cancel the next capture.
    private(set) var owner: String?

    /// The effect of one input from the active controller.
    ///
    /// `toggleCaptureActive` is whether a capture started by a source with no
    /// press/release pair (the keyboard, the mic button) is running: the
    /// controller never owned that capture, so a hold press during it is
    /// ignored rather than treated as a second hold (§C).
    mutating func effect(
        for action: Action,
        control: String,
        phase: ControlPhase,
        toggleCaptureActive: Bool
    ) -> HoldEffect {
        switch phase {
        case .ended:
            // Only the control that started the hold can end it; every other
            // release — including both releases after a cancel — does nothing.
            // Ownership alone decides, not the action mapped now: a mapping
            // edit mid-hold must not strand the recorder (as `pttHoldButton`).
            guard owner == control else { return .ignore }
            owner = nil
            return .endCapture

        case .began:
            guard let mode = Self.captureMode(for: action) else {
                guard let intent = IntentMapper.intent(for: action, phase: .began) else { return .ignore }
                return .deliver(intent)
            }
            // A second hold-mapped press on the active controller while a hold
            // capture is running cancels both: the partial capture is dropped,
            // so neither control's later release can send it.
            if owner != nil {
                owner = nil
                return .cancelCapture
            }
            // A capture the controller does not own (keyboard, mic button) is
            // not cancelled by a press on the pad.
            guard !toggleCaptureActive else { return .ignore }
            owner = control
            return .beginCapture(mode)
        }
    }

    /// Ends a hold the active controller owns when it can no longer be
    /// released normally: that controller disconnected, or the Controller slot
    /// changed (§C). A toggle-started capture is left alone.
    mutating func releaseAll() -> HoldEffect {
        guard owner != nil else { return .ignore }
        owner = nil
        return .endCapture
    }

    /// The capture mode a hold action starts, or `nil` for an action that fires
    /// once on the press. Mirrors `Action.isHoldAction`; the split is pinned by
    /// `HoldTrackerTests.testEveryHoldActionBeginsACaptureAndNoOtherActionDoes`.
    private static func captureMode(for action: Action) -> VoiceCaptureMode? {
        switch action {
        case .pushToTalk: return .send
        case .pushToTalkDraft: return .draft
        default: return nil
        }
    }
}
