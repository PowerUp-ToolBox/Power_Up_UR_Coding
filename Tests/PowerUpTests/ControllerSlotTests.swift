import XCTest
@testable import PowerUp

/// Pins the Controller slot rule (#128, DESIGN.md v2.7 addendum §B, ADR 0013):
/// the connected controllers, most recently connected first, and the pinned id
/// go in as plain data; the controller in the slot comes out. No hardware, no
/// framework callbacks, no async waits — the order is the input array's order.
final class ControllerSlotTests: XCTestCase {

    private func controller(
        _ id: String,
        profileID: String = "dualsense"
    ) -> ConnectedController {
        ConnectedController(id: id, profileID: profileID, displayName: "Pad \(id)")
    }

    /// Automatic: the most recently connected controller fills the slot.
    func testAutomaticSelectsMostRecentlyConnectedController() {
        let slot = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("couch"), controller("desk")],
            pinnedID: nil
        )

        XCTAssertEqual(
            slot.active,
            controller("couch"),
            "Automatic must take the head of the list, the most recent connection"
        )
    }

    /// A pinned id wins over a more recently connected pad.
    func testPinnedControllerThatIsConnectedFillsTheSlot() {
        let slot = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("couch"), controller("desk")],
            pinnedID: "desk"
        )

        XCTAssertEqual(slot.active?.id, "desk")
    }

    /// Pinned but absent: the slot stays empty instead of falling back to
    /// Automatic, so a pad nobody pinned never responds.
    func testPinnedControllerThatIsAbsentLeavesTheSlotEmpty() {
        let slot = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("couch")],
            pinnedID: "desk"
        )

        XCTAssertNil(
            slot.active,
            "A pinned-absent controller leaves the slot empty; it must not fall back to Automatic"
        )
    }

    /// Automatic: the active controller disconnecting hands the slot to the
    /// next most recently connected one, never a stale controller.
    func testDisconnectFallsToTheNextMostRecentlyConnectedController() {
        let before = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("couch"), controller("desk")],
            pinnedID: nil
        )
        XCTAssertEqual(before.active?.id, "couch")

        let after = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("desk")],
            pinnedID: nil
        )
        XCTAssertEqual(after.active?.id, "desk")
    }

    /// A pinned pad that reconnects takes the slot back with no new pinning.
    func testReturningPinnedControllerTakesTheSlotBack() {
        let away = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("desk")],
            pinnedID: "couch"
        )
        XCTAssertNil(away.active)

        let back = ControllerSlotSelector(
            mostRecentlyConnectedFirst: [controller("couch"), controller("desk")],
            pinnedID: "couch"
        )
        XCTAssertEqual(back.active?.id, "couch")
    }

    /// Nothing connected: the slot is empty, whether pinned or Automatic.
    func testEmptyConnectedListLeavesTheSlotEmpty() {
        let automatic = ControllerSlotSelector(mostRecentlyConnectedFirst: [], pinnedID: nil)
        XCTAssertNil(automatic.active)

        let pinned = ControllerSlotSelector(mostRecentlyConnectedFirst: [], pinnedID: "couch")
        XCTAssertNil(pinned.active)
    }
}

/// Pins the hold rule (#129, DESIGN.md v2.7 addendum §C): a press or release on
/// the active controller goes in, the effect on the voice capture and the
/// tracker's owner come out. Plain data in, plain data out — no hardware, no
/// recognizer, no async waits — so the inputs and the expected effects can be
/// lifted into the shared fixtures the Rust core will use.
final class HoldTrackerTests: XCTestCase {

    /// One tracker input as plain data: everything §C lets the tracker see.
    private struct HoldInput {
        var action: Action
        var control: String
        var phase: ControlPhase
        var toggleCaptureActive = false
    }

    /// Every action a profile can map, for the hold/non-hold consistency rule.
    private static let everyAction: [Action] = [
        .none, .pushToTalk, .sendPrompt("fix the failing test"), .approve, .reject,
        .interrupt, .stopSpeaking, .replayLastReply, .toggleTTS, .newSession,
        .showWindow, .cycleModel, .cycleEffort, .cyclePermissionMode, .cycleProject,
        .cycleFocus, .pushToTalkDraft, .sendDraft, .toggleControlMode,
    ]

    /// Drives a whole sequence through one tracker and returns both plain
    /// outputs: the effect per input, and the owner left behind.
    private func run(
        _ inputs: [HoldInput],
        from tracker: HoldTracker = HoldTracker()
    ) -> (effects: [HoldEffect], owner: String?) {
        var tracker = tracker
        var effects: [HoldEffect] = []
        for input in inputs {
            effects.append(
                tracker.effect(
                    for: input.action,
                    control: input.control,
                    phase: input.phase,
                    toggleCaptureActive: input.toggleCaptureActive
                )
            )
        }
        return (effects, tracker.owner)
    }

    /// §C "ownership is the control that started it": a hold press begins a
    /// capture in the action's own mode and records that control as the owner.
    func testHoldPressBeginsACaptureWithTheActionsModeAndRecordsTheOwner() {
        let send = run([HoldInput(action: .pushToTalk, control: "r2", phase: .began)])
        XCTAssertEqual(send.effects, [.beginCapture(.send)])
        XCTAssertEqual(send.owner, "r2")

        let draft = run([HoldInput(action: .pushToTalkDraft, control: "l2", phase: .began)])
        XCTAssertEqual(draft.effects, [.beginCapture(.draft)])
        XCTAssertEqual(draft.owner, "l2")
    }

    /// §C "ownership is the control that started it": the owner's release ends
    /// the capture and clears the owner.
    func testOwnerReleaseEndsTheCaptureAndClearsTheOwner() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .pushToTalk, control: "r2", phase: .ended),
        ])

        XCTAssertEqual(effects, [.beginCapture(.send), .endCapture])
        XCTAssertNil(owner)
    }

    /// §C "ownership as today (`pttHoldButton`)": the owner's release ends the
    /// capture whatever the control is mapped to *now*, so a mapping edit
    /// mid-hold cannot strand the recorder or turn the next hold into a cancel.
    func testOwnerReleaseEndsTheCaptureEvenAfterAMidHoldRemap() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .approve, control: "r2", phase: .ended),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .began),
        ])

        XCTAssertEqual(effects, [.beginCapture(.send), .endCapture, .beginCapture(.draft)])
        XCTAssertEqual(owner, "l2")
    }

    /// §C "ownership is the control that started it": a release from any other
    /// control does nothing, and never ends or steals the running hold.
    func testNonOwnerReleaseIsIgnored() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .ended),
        ])

        XCTAssertEqual(effects, [.beginCapture(.send), .ignore])
        XCTAssertEqual(owner, "r2", "a non-owner release must not end the running hold")
    }

    /// §C "two holds on the active controller cancel both": the second hold
    /// press cancels rather than ends — an end would send the half sentence —
    /// and clears the owner, leaving the tracker idle so a new hold can start.
    func testSecondHoldPressDuringAControllerOwnedCaptureCancelsBoth() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .began),
        ])

        XCTAssertEqual(
            effects,
            [.beginCapture(.send), .cancelCapture],
            "the second hold press must cancel, never end: an end would send the partial transcript"
        )
        XCTAssertNil(owner, "a cancel clears the owner")

        // The tracker is idle again: a fresh hold press begins a new capture.
        let (restarted, restartedOwner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .began),
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
        ])
        XCTAssertEqual(restarted, [.beginCapture(.send), .cancelCapture, .beginCapture(.send)])
        XCTAssertEqual(restartedOwner, "r2")
    }

    /// §C "neither control's later release does anything": both releases after
    /// a cancel are ignored, so nothing half-finished is ever sent or drafted.
    func testReleasesAfterACancelAreIgnored() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .began),
            HoldInput(action: .pushToTalk, control: "r2", phase: .ended),
            HoldInput(action: .pushToTalkDraft, control: "l2", phase: .ended),
        ])

        XCTAssertEqual(
            effects,
            [.beginCapture(.send), .cancelCapture, .ignore, .ignore],
            "a release after a cancel must never deliver an intent"
        )
        XCTAssertNil(owner)
    }

    /// §C "a hold press while a toggle-started capture is active is still
    /// ignored (v2.6), not a cancel": the pad never owned that capture, so it
    /// cannot interrupt a keyboard or mic-button dictation.
    func testHoldPressDuringAToggleStartedCaptureIsIgnored() {
        let (effects, owner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began, toggleCaptureActive: true),
        ])

        XCTAssertEqual(effects, [.ignore], "a pad press must never cancel a capture the pad does not own")
        XCTAssertNil(owner, "an ignored press must not take ownership")

        let (released, releasedOwner) = run([
            HoldInput(action: .pushToTalk, control: "r2", phase: .began, toggleCaptureActive: true),
            HoldInput(action: .pushToTalk, control: "r2", phase: .ended, toggleCaptureActive: true),
        ])
        XCTAssertEqual(released, [.ignore, .ignore])
        XCTAssertNil(releasedOwner)
    }

    /// §C: a non-hold action fires once, on the press — the release of the
    /// same control does nothing, and it never takes hold ownership.
    func testNonHoldActionDeliversItsIntentOnPressAndNothingOnRelease() {
        let (effects, owner) = run([
            HoldInput(action: .approve, control: "cross", phase: .began),
            HoldInput(action: .approve, control: "cross", phase: .ended),
        ])

        XCTAssertEqual(effects, [.deliver(.approve), .ignore])
        XCTAssertNil(owner, "a non-hold action never takes hold ownership")

        let prompted = run([HoldInput(action: .sendPrompt("status"), control: "square", phase: .began)])
        XCTAssertEqual(prompted.effects, [.deliver(.sendPrompt("status"))])
    }

    /// A control mapped to nothing has nothing to deliver or begin.
    func testUnmappedNonHoldActionIsIgnored() {
        let (effects, owner) = run([
            HoldInput(action: .none, control: "touchpad", phase: .began),
            HoldInput(action: .none, control: "touchpad", phase: .ended),
        ])

        XCTAssertEqual(effects, [.ignore, .ignore])
        XCTAssertNil(owner)
    }

    /// §C: the disconnect safety net and a Controller slot change end a
    /// controller-owned hold, so the mic can never stay wedged on a pad that
    /// is gone or no longer in the slot.
    func testReleaseAllOnDisconnectOrSlotChangeEndsAControllerOwnedCapture() {
        var tracker = HoldTracker()
        XCTAssertEqual(
            tracker.effect(for: .pushToTalk, control: "r2", phase: .began, toggleCaptureActive: false),
            .beginCapture(.send)
        )

        XCTAssertEqual(tracker.releaseAll(), .endCapture)
        XCTAssertNil(tracker.owner, "release-all clears the owner")

        // Nothing controller-owned to release: both call sites are no-ops.
        XCTAssertEqual(tracker.releaseAll(), .ignore, "a second release-all has nothing to end")
    }

    /// §C "keeps its v2.6 narrowing": release-all is scoped to holds the pad
    /// owns, so a keyboard or mic-button capture is left alone by a pad
    /// disconnecting or by a slot change.
    func testReleaseAllLeavesAToggleStartedCaptureAlone() {
        var tracker = HoldTracker()
        XCTAssertEqual(
            tracker.effect(for: .pushToTalk, control: "r2", phase: .began, toggleCaptureActive: true),
            .ignore
        )

        XCTAssertEqual(
            tracker.releaseAll(),
            .ignore,
            "a toggle-started capture must survive both the disconnect and the slot-change release"
        )
        XCTAssertNil(tracker.owner)
    }

    /// The tracker's hold/non-hold split is exactly `Action.isHoldAction`:
    /// every hold action begins a capture, and no other action ever does.
    func testEveryHoldActionBeginsACaptureAndNoOtherActionDoes() {
        for action in Self.everyAction {
            let (effects, owner) = run([HoldInput(action: action, control: "r2", phase: .began)])
            let expectation: String = action.isHoldAction ? "a hold action" : "not a hold action"

            if action.isHoldAction {
                guard effects.count == 1, case .beginCapture = effects[0] else {
                    XCTFail("\(action) is \(expectation) and must begin a capture, got \(effects)")
                    continue
                }
                XCTAssertEqual(owner, "r2")
            } else {
                if case .beginCapture = effects[0] {
                    XCTFail("\(action) is \(expectation) and must never begin a capture")
                }
                XCTAssertNil(owner)
            }
        }
    }
}
