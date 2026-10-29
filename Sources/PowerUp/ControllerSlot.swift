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
/// A value type (CONTEXT.md: Slot, Controller; ADR 0013; DESIGN.md v2.7
/// addendum §B): the connected controllers in connection order and the pinned
/// id go in, the controller in the slot comes out. The rule itself lives in
/// the Rust core (`powerup-core` `slots::select_active_controller`, DESIGN.md
/// v2.11); this is its Swift face. The order is the input list's own order —
/// spelled out in the parameter label so a caller cannot pass a differently
/// ordered list and get a plausible wrong answer — never a framework
/// callback's arrival order, and nothing here is observable or mutable.
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
        CoreBridge.activeController(mostRecentlyConnectedFirst: mostRecentlyConnectedFirst,
                                    pinnedID: pinnedID)
    }
}

// MARK: - Hold

/// What one input on the active controller does to the voice capture
/// (DESIGN.md v2.7 addendum §C). Plain data: the Swift face of the core's
/// `hold::HoldEffect`, which the AppState adapter switches on.
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
/// A value type (CONTEXT.md: Hold, Action, Control; DESIGN.md v2.7 addendum
/// §C). The action, the control id, the phase and whether a toggle-started
/// capture is running go in; one `HoldEffect` per input comes out, alongside
/// the owner this tracker keeps. The rule lives in the Rust core
/// (`powerup-core` `hold::HoldState`, DESIGN.md v2.11): the owner is the
/// core's whole state, passed in on every input and replaced by the one that
/// comes back. Nothing here knows about framework callbacks, the recognizer
/// or haptics — the AppState adapter does.
struct HoldTracker: Equatable {
    /// The control id that started the running hold, or `nil` when the active
    /// controller owns no capture. Cleared by the owner's release and by a
    /// cancel. When a capture ends anywhere else (a toggle, a denied speech
    /// permission, a vanished microphone), the adapter must replace the
    /// tracker with a fresh `HoldTracker()`, or a stale owner would cancel the
    /// next capture.
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
        let step = CoreBridge.holdStep(owner: owner, action: action, control: control,
                                       phase: phase, toggleCaptureActive: toggleCaptureActive)
        owner = step.owner
        return step.effect
    }

    /// Ends a hold the active controller owns when it can no longer be
    /// released normally: that controller disconnected, or the Controller slot
    /// changed (§C). A toggle-started capture is left alone.
    mutating func releaseAll() -> HoldEffect {
        let step = CoreBridge.holdReleaseAll(owner: owner)
        owner = step.owner
        return step.effect
    }
}
