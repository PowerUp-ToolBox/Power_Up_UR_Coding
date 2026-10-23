import XCTest
import GameController
@testable import PowerUp

/// The Controller slot inside `ControllerService` (DESIGN.md v2.7 addendum
/// §B, ticket #130): every connected controller is listed with an id that is
/// stable for its connection, most recent first; `ControllerSlotSelector`
/// with the pinned id picks the one active controller; and only that one
/// delivers presses, receives light and haptic writes, and reports battery.
/// The other pads are listed for the picker and otherwise inert.
///
/// Driven entirely by the pad-free test hooks (#113): no GameController
/// device is needed or touched.
@MainActor
final class ControllerServiceSlotTests: XCTestCase {

    private static let off = ControllerOutput.light(r: 0, g: 0, b: 0)
    private static let blue = ControllerOutput.light(r: 0, g: 0.25, b: 1)

    // MARK: The connected list and ids

    func testConnectedListIsMostRecentFirstAndTheNewestIsActiveInAutomatic() {
        let controller = ControllerService()

        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")

        XCTAssertEqual(controller.connected, [couch, desk])
        XCTAssertEqual(controller.active, couch, "Automatic: the most recently connected fills the slot")
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.controllerName, "Couch Pad", "the status card shows the pad in the slot")
        XCTAssertEqual(desk.profileID, DeviceProfile.dualSenseID)
        XCTAssertEqual(desk.displayName, "Desk Pad")
    }

    func testAnIDStaysTheSameForTheLifeOfItsConnection() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")

        let couch = controller.simulateConnect(name: "Couch Pad")
        controller.simulateDisconnect(couch.id)

        XCTAssertEqual(controller.connected.map(\.id), [desk.id],
                       "another pad coming and going does not renumber this one")
    }

    func testTwoIdenticalPadsGetDistinctIDsAndNames() {
        let controller = ControllerService()

        let first = controller.simulateConnect()
        let second = controller.simulateConnect()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.displayName, second.displayName,
                          "the picker can tell two identical pads apart")
    }

    func testTheSamePadReconnectingGetsTheSameID() {
        let controller = ControllerService()
        let pad = controller.simulateConnect(name: "Desk Pad")

        controller.simulateDisconnect(pad.id)
        let again = controller.simulateConnect(name: "Desk Pad")

        XCTAssertEqual(again.id, pad.id, "a pin on this pad survives it reconnecting")
    }

    // MARK: Only the active controller delivers presses

    func testOnlyTheActiveControllerDeliversButtons() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        var downs: [String] = []
        controller.onButtonDown = { downs.append($0.rawValue) }

        controller.simulateButton(.cross, pressed: true, on: desk.id)
        controller.simulateButton(.cross, pressed: false, on: desk.id)
        XCTAssertTrue(downs.isEmpty, "a press on the pad not in the slot does nothing")

        controller.simulateButton(.circle, pressed: true, on: couch.id)
        XCTAssertEqual(downs, [ControllerButton.circle.rawValue])
    }

    func testAPinnedControllerFillsTheSlotAndTheNewerOneIsInert() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        var downs: [String] = []
        controller.onButtonDown = { downs.append($0.rawValue) }

        controller.pinnedControllerID = desk.id

        XCTAssertEqual(controller.active, desk)
        XCTAssertEqual(controller.connected, [couch, desk], "the list order does not change with a pin")
        controller.simulateButton(.cross, pressed: true, on: couch.id)
        controller.simulateButton(.square, pressed: true, on: desk.id)
        XCTAssertEqual(downs, [ControllerButton.square.rawValue])
    }

    func testAPinnedControllerThatIsNotConnectedLeavesTheSlotEmpty() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        var downs = 0
        controller.onButtonDown = { _ in downs += 1 }

        controller.pinnedControllerID = "a-pad-that-is-switched-off"

        XCTAssertNil(controller.active)
        XCTAssertFalse(controller.isConnected, "nothing fills the slot, so nothing responds")
        XCTAssertNil(controller.controllerName)
        XCTAssertEqual(controller.connected, [desk], "the connected pad is still listed for the picker")
        controller.simulateButton(.cross, pressed: true, on: desk.id)
        XCTAssertEqual(downs, 0)
    }

    func testAPinnedControllerReconnectingTakesTheSlotBack() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        controller.pinnedControllerID = desk.id

        controller.simulateDisconnect(desk.id)
        XCTAssertNil(controller.active, "a pin never falls back to another pad")
        XCTAssertEqual(controller.connected, [couch])

        let back = controller.simulateConnect(name: "Desk Pad")
        XCTAssertEqual(back.id, desk.id)
        XCTAssertEqual(controller.active, back, "the pinned pad takes the slot back by itself")
    }

    func testClearingThePinReturnsToAutomatic() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        controller.pinnedControllerID = desk.id

        controller.pinnedControllerID = nil

        XCTAssertEqual(controller.active, couch)
    }

    // MARK: Leaving the slot

    func testAutomaticFallsBackToTheNextMostRecentWhenTheActiveDisconnects() {
        let controller = ControllerService()
        let first = controller.simulateConnect(name: "First")
        let second = controller.simulateConnect(name: "Second")
        let third = controller.simulateConnect(name: "Third")
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("left the slot") }
        controller.simulateButton(.r2, pressed: true, on: third.id)

        controller.simulateDisconnect(third.id)

        XCTAssertEqual(controller.active, second)
        XCTAssertEqual(controller.connected, [second, first])
        XCTAssertEqual(controller.controllerName, "Second")
        XCTAssertEqual(events, ["up \(ControllerButton.r2.rawValue)", "left the slot"],
                       "the dropped pad's held trigger is released before the drop is reported")
    }

    func testAnInactiveControllerDisconnectingLeavesTheSlotAlone() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("left the slot") }
        controller.simulateButton(.r2, pressed: true, on: couch.id)

        controller.simulateDisconnect(desk.id)

        XCTAssertEqual(controller.active, couch)
        XCTAssertTrue(events.isEmpty, "the hold on the active pad is untouched")
        controller.simulateButton(.r2, pressed: false, on: couch.id)
        XCTAssertEqual(events, ["up \(ControllerButton.r2.rawValue)"])
    }

    /// v2.7 §C: the hold of a controller that leaves the slot is released,
    /// whether it disconnected or another controller took the slot.
    func testANewerControllerTakingTheSlotReleasesTheOldOnesHeldButtons() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("left the slot") }
        controller.simulateButton(.r2, pressed: true, on: desk.id)

        let couch = controller.simulateConnect(name: "Couch Pad")

        XCTAssertEqual(controller.active, couch)
        XCTAssertEqual(events, ["up \(ControllerButton.r2.rawValue)", "left the slot"])
        controller.simulateButton(.r2, pressed: false, on: desk.id)
        controller.simulateButton(.r2, pressed: false, on: couch.id)
        XCTAssertEqual(events.count, 2, "no stale release from either pad")
    }

    func testPinningAnotherControllerReleasesTheOldOnesHeldButtons() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("left the slot") }
        controller.simulateButton(.l2, pressed: true, on: couch.id)

        controller.pinnedControllerID = desk.id

        XCTAssertEqual(events, ["up \(ControllerButton.l2.rawValue)", "left the slot"])
    }

    func testAPadConnectingWhileThePinnedOneIsActiveChangesNothing() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        controller.pinnedControllerID = desk.id
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("left the slot") }
        controller.simulateButton(.r2, pressed: true, on: desk.id)

        controller.simulateConnect(name: "Couch Pad")

        XCTAssertEqual(controller.active, desk)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Light and haptics go to the active controller only

    func testLightAndHapticWritesGoOnlyToTheActiveController() {
        let controller = ControllerService()
        controller.recordsOutput = true
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        controller.clearRecordedOutput()

        controller.setLight(r: 0, g: 0.25, b: 1)
        controller.rumble(intensity: 0.5, duration: 0.05)

        XCTAssertEqual(controller.recordedWrites, [
            ControllerOutputRecord(controllerID: couch.id, output: Self.blue),
            ControllerOutputRecord(controllerID: couch.id, output: .rumble(intensity: 0.5, duration: 0.05))
        ])

        controller.clearRecordedOutput()
        controller.pinnedControllerID = desk.id
        controller.setLight(r: 0, g: 0.25, b: 1)

        XCTAssertEqual(controller.recordedWrites, [
            ControllerOutputRecord(controllerID: couch.id, output: Self.off),
            ControllerOutputRecord(controllerID: desk.id, output: Self.blue)
        ], "the pad leaving the slot goes dark; only the new active one gets the color")
    }

    func testAControllerThatConnectsOutsideTheSlotIsDarkened() {
        let controller = ControllerService()
        controller.recordsOutput = true
        let desk = controller.simulateConnect(name: "Desk Pad")
        controller.pinnedControllerID = desk.id
        controller.clearRecordedOutput()

        let couch = controller.simulateConnect(name: "Couch Pad")
        controller.setLight(r: 0, g: 0.25, b: 1)

        XCTAssertEqual(controller.recordedWrites, [
            ControllerOutputRecord(controllerID: couch.id, output: Self.off),
            ControllerOutputRecord(controllerID: desk.id, output: Self.blue)
        ])
    }

    func testWithTheSlotEmptyWritesReachNoController() {
        let controller = ControllerService()
        controller.recordsOutput = true
        controller.simulateConnect(name: "Desk Pad")
        controller.pinnedControllerID = "switched-off"
        controller.clearRecordedOutput()

        controller.setLight(r: 1, g: 0, b: 0)
        controller.rumble(intensity: 0.9, duration: 0.06)

        XCTAssertEqual(controller.recordedWrites.map(\.controllerID), [nil, nil])
    }

    // MARK: Battery comes from the active controller only

    func testBatteryIsReportedForTheActiveControllerOnly() {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")

        controller.simulateBattery(level: 0.9, state: .discharging, on: desk.id)
        XCTAssertNil(controller.batteryLevel, "the pad not in the slot reports nothing")

        controller.simulateBattery(level: 0.6, state: .charging, on: couch.id)
        XCTAssertEqual(controller.batteryLevel, 0.6)
        XCTAssertTrue(controller.isCharging)

        controller.pinnedControllerID = desk.id
        XCTAssertEqual(controller.batteryLevel, 0.9, "the gauge follows the slot")
        XCTAssertFalse(controller.isCharging)
    }

    func testLowBatteryWarnsOnlyForTheActiveController() {
        let controller = ControllerService()
        let drawer = controller.simulateConnect(name: "Spare Pad")
        let active = controller.simulateConnect(name: "Couch Pad")
        var warnings: [Float] = []
        controller.onLowBattery = { warnings.append($0) }

        controller.simulateBattery(level: 0.05, state: .discharging, on: drawer.id)
        XCTAssertTrue(warnings.isEmpty, "a spare pad in a drawer never interrupts")

        controller.simulateBattery(level: 0.15, state: .discharging, on: active.id)
        controller.simulateBattery(level: 0.12, state: .discharging, on: active.id)
        XCTAssertEqual(warnings, [0.15], "once per connection, for the pad in the slot")
    }

    func testALowControllerThatTakesTheSlotWarnsThen() {
        let controller = ControllerService()
        let spare = controller.simulateConnect(name: "Spare Pad")
        let active = controller.simulateConnect(name: "Couch Pad")
        var warnings: [Float] = []
        controller.onLowBattery = { warnings.append($0) }
        controller.simulateBattery(level: 0.1, state: .discharging, on: spare.id)
        XCTAssertTrue(warnings.isEmpty)

        controller.simulateDisconnect(active.id)

        XCTAssertEqual(controller.active, spare)
        XCTAssertEqual(warnings, [0.1], "now it is the pad in use, so its low battery matters")
    }

    /// v2.3 A: the latch resets on a fallback swap, so the pad that takes
    /// the slot after a warned one dies still gets its own warning.
    func testTheControllerTakingTheSlotAfterAWarningGetsItsOwnWarning() {
        let controller = ControllerService()
        let spare = controller.simulateConnect(name: "Spare Pad")
        let active = controller.simulateConnect(name: "Couch Pad")
        var warnings: [Float] = []
        controller.onLowBattery = { warnings.append($0) }
        controller.simulateBattery(level: 0.18, state: .discharging, on: spare.id)
        controller.simulateBattery(level: 0.05, state: .discharging, on: active.id)
        XCTAssertEqual(warnings, [0.05])

        controller.simulateDisconnect(active.id)

        XCTAssertEqual(warnings, [0.05, 0.18])
    }
}
