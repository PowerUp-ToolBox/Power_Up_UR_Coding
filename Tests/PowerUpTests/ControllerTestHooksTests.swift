import XCTest
@testable import PowerUp

/// The ControllerService's internal test hooks (#113): a simulated pad that
/// connects, presses and drops through the same paths GameController drives,
/// and a recorder for the light and haptic writes that would reach the pad.
/// No hardware is needed or touched.
@MainActor
final class ControllerTestHooksTests: XCTestCase {

    // MARK: Connection state

    func testSimulatedConnectAndDisconnectSetTheConnectionState() {
        let controller = ControllerService()
        XCTAssertFalse(controller.isConnected)

        controller.simulateConnect(name: "Test Pad", isDualSense: true)
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.controllerName, "Test Pad")
        XCTAssertTrue(controller.isDualSense)

        var disconnects = 0
        controller.onDisconnect = { disconnects += 1 }
        controller.simulateDisconnect()

        XCTAssertFalse(controller.isConnected)
        XCTAssertNil(controller.controllerName)
        XCTAssertFalse(controller.isDualSense)
        XCTAssertNil(controller.batteryLevel)
        XCTAssertEqual(disconnects, 1)
    }

    func testDisconnectWithNoPadDoesNothing() {
        let controller = ControllerService()
        var disconnects = 0
        controller.onDisconnect = { disconnects += 1 }

        controller.simulateDisconnect()

        XCTAssertEqual(disconnects, 0, "only a connected pad can drop")
    }

    // MARK: Simulated presses

    func testSimulatedPressesAreDeDupedLikeThePadsOwnInput() {
        let controller = ControllerService()
        controller.simulateConnect()
        var events: [String] = []
        controller.onButtonDown = { events.append("down \($0.rawValue)") }
        controller.onButtonUp = { events.append("up \($0.rawValue)") }

        controller.simulateButton(.r2, pressed: true)
        controller.simulateButton(.r2, pressed: true)   // trigger jitter
        controller.simulateButton(.r2, pressed: false)
        controller.simulateButton(.r2, pressed: false)  // stray up

        XCTAssertEqual(events, ["down \(ControllerButton.r2.rawValue)",
                                "up \(ControllerButton.r2.rawValue)"])
    }

    func testPressesWithoutAPadAreIgnored() {
        let controller = ControllerService()
        var downs = 0
        controller.onButtonDown = { _ in downs += 1 }

        controller.simulateButton(.cross, pressed: true)

        XCTAssertEqual(downs, 0)
    }

    func testDisconnectReleasesHeldButtonsBeforeReportingTheDrop() {
        let controller = ControllerService()
        controller.simulateConnect()
        var events: [String] = []
        controller.onButtonUp = { events.append("up \($0.rawValue)") }
        controller.onDisconnect = { events.append("disconnect") }

        controller.simulateButton(.r2, pressed: true)
        controller.simulateDisconnect()

        XCTAssertEqual(events, ["up \(ControllerButton.r2.rawValue)", "disconnect"])

        // The held set was cleared: a reconnect starts with nothing held.
        controller.simulateConnect()
        controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(events.count, 2, "no stale release after a reconnect")
    }

    // MARK: Recorded output

    func testOutputIsNotRecordedByDefault() {
        let controller = ControllerService()

        controller.setLight(r: 1, g: 0, b: 0)
        controller.rumble(intensity: 0.5, duration: 0.05)

        XCTAssertFalse(controller.recordsOutput, "production never records")
        XCTAssertTrue(controller.recordedOutput.isEmpty)
    }

    func testLightAndHapticWritesAreRecordedEvenWithoutAPad() {
        let controller = ControllerService()
        controller.recordsOutput = true

        controller.setLight(r: 1, g: 0.5, b: 0)
        controller.rumble(intensity: 0.9, duration: 0.06)

        XCTAssertEqual(controller.recordedOutput, [
            .light(r: 1, g: 0.5, b: 0),
            .rumble(intensity: 0.9, duration: 0.06)
        ])

        controller.clearRecordedOutput()
        XCTAssertTrue(controller.recordedOutput.isEmpty)
    }
}
