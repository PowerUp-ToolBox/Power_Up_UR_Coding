import XCTest
import GameController
@testable import PowerUp

/// The Controller slot driven through the AppState seam (ticket #130,
/// DESIGN.md v2.7 addendum §B): with two simulated pads connected, only the
/// one in the slot moves status, fires actions, gets the light and warns
/// about its battery; the configuration's pinned id decides which one that
/// is. The keyboard is outside the slot model and is covered by the v2.6
/// suites, which keep passing unchanged.
@MainActor
final class AppStateControllerSlotTests: XCTestCase {

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    private static let idleBlue = ControllerOutput.light(r: 0.0, g: 0.25, b: 1.0)
    private static let off = ControllerOutput.light(r: 0.0, g: 0.0, b: 0.0)
    private static let buzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-slot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false            // TTS is real in the seam; keep it silent.
        config.projectDir = sandbox.path
        config.mapping[.r2] = .pushToTalk
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
        if let projectDir { try? FileManager.default.removeItem(at: projectDir) }
        projectDir = nil
    }

    private struct Rig {
        let app: AppState
        let controller: ControllerService
        let desk: ConnectedController
        let couch: ConnectedController
        let transcriptBaseline: Int
    }

    /// Two pads, desk connected first, couch second (so Automatic picks the
    /// couch), the output recorded, settled at .idle.
    private func makeRig(pinnedID: (ConnectedController) -> String? = { _ in nil }) async -> Rig {
        let controller = ControllerService()
        controller.recordsOutput = true
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        let store = env.makeConfigStore()
        store.config.controllerDeviceID = pinnedID(desk)
        let app = env.makeAppState(configStore: store,
                                   controller: controller,
                                   speech: SpeechService(engine: ScriptedSpeechEngine()),
                                   harness: FakeHarnessAdapter())
        await settle(until: app.status == .idle)
        return Rig(app: app, controller: controller, desk: desk, couch: couch,
                   transcriptBaseline: app.transcript.count)
    }

    private func batteryWarnings(_ rig: Rig) -> [String] {
        rig.app.transcript.dropFirst(rig.transcriptBaseline)
            .map(\.text)
            .filter { $0.contains("battery is low") }
    }

    // MARK: Low battery

    func testLowBatteryWarningFiresOnlyForTheActivePad() async {
        let rig = await makeRig()
        rig.controller.clearRecordedOutput()

        rig.controller.simulateBattery(level: 0.05, state: .discharging, on: rig.desk.id)

        XCTAssertTrue(batteryWarnings(rig).isEmpty, "the spare pad never interrupts")
        XCTAssertTrue(rig.controller.recordedWrites.isEmpty, "and nothing buzzes")

        rig.controller.simulateBattery(level: 0.1, state: .discharging, on: rig.couch.id)

        XCTAssertEqual(batteryWarnings(rig), ["🔋 Controller battery is low (10%) — plug it in soon."])
        XCTAssertEqual(rig.controller.recordedWrites.first,
                       ControllerOutputRecord(controllerID: rig.couch.id, output: Self.buzz),
                       "the warning buzzes the pad in the slot")
        withExtendedLifetime(rig.app) {}
    }

    func testLowBatteryOfAPinnedPadWarnsAndTheNewerPadStaysQuiet() async {
        let rig = await makeRig(pinnedID: { $0.id })
        XCTAssertEqual(rig.controller.active, rig.desk)

        rig.controller.simulateBattery(level: 0.05, state: .discharging, on: rig.couch.id)
        XCTAssertTrue(batteryWarnings(rig).isEmpty)

        rig.controller.simulateBattery(level: 0.15, state: .discharging, on: rig.desk.id)
        XCTAssertEqual(batteryWarnings(rig).count, 1)
        withExtendedLifetime(rig.app) {}
    }

    // MARK: Light

    func testTheLightGoesOnlyToThePadInTheSlot() async {
        let rig = await makeRig()

        let colored = rig.controller.recordedWrites.filter { $0.output != Self.off }
        XCTAssertFalse(colored.isEmpty)
        XCTAssertTrue(colored.allSatisfy { $0.controllerID == rig.couch.id },
                      "only the active pad gets a color: \(rig.controller.recordedWrites)")
        XCTAssertEqual(lastLight(rig, on: rig.couch.id), Self.idleBlue)
        XCTAssertNotEqual(lastLight(rig, on: rig.desk.id), Self.idleBlue, "the other pad is never lit")
        withExtendedLifetime(rig.app) {}
    }

    func testPinningTheOtherPadInSettingsMovesTheLight() async {
        let rig = await makeRig()
        rig.controller.clearRecordedOutput()

        rig.app.configStore.config.controllerDeviceID = rig.desk.id
        await settle(until: rig.controller.active == rig.desk)
        await settle(until: self.lastLight(rig, on: rig.desk.id) == Self.idleBlue)

        XCTAssertEqual(lastLight(rig, on: rig.couch.id), Self.off, "the pad that left the slot goes dark")
        XCTAssertTrue(rig.controller.recordedWrites
                        .filter { $0.output != Self.off }
                        .allSatisfy { $0.controllerID == rig.desk.id })
        XCTAssertEqual(rig.app.status, .idle)
        withExtendedLifetime(rig.app) {}
    }

    // MARK: Presses and status

    func testOnlyTheActivePadFiresActions() async {
        let rig = await makeRig(pinnedID: { $0.id })

        rig.controller.simulateButton(.r2, pressed: true, on: rig.couch.id)
        XCTAssertFalse(rig.app.isPTTActive, "the pad outside the slot is inert")
        XCTAssertEqual(rig.app.status, .idle)

        rig.controller.simulateButton(.r2, pressed: true, on: rig.desk.id)
        XCTAssertTrue(rig.app.isPTTActive)
        XCTAssertEqual(rig.app.status, .listening)
        rig.controller.simulateButton(.r2, pressed: false, on: rig.desk.id)
        XCTAssertFalse(rig.app.isPTTActive)
        withExtendedLifetime(rig.app) {}
    }

    func testAPinnedPadThatIsOffLeavesTheAppWithNoController() async {
        let controller = ControllerService()
        let desk = controller.simulateConnect(name: "Desk Pad")
        let store = env.makeConfigStore()
        store.config.controllerDeviceID = "a-pad-that-is-switched-off"
        let app = env.makeAppState(configStore: store,
                                   controller: controller,
                                   speech: SpeechService(engine: ScriptedSpeechEngine()),
                                   harness: FakeHarnessAdapter())

        XCTAssertNil(controller.active)
        XCTAssertEqual(app.status, .noController)
        controller.simulateButton(.r2, pressed: true, on: desk.id)
        XCTAssertFalse(app.isPTTActive)

        app.configStore.config.controllerDeviceID = nil   // back to Automatic
        await settle(until: app.status == .idle)
        XCTAssertEqual(controller.active, desk)
    }

    // MARK: Settings → Devices picker (#132)

    private func pickerRows(_ rig: Rig) -> [ControllerPickerRow] {
        ControllerPicker.rows(connected: rig.controller.connected,
                              active: rig.controller.active,
                              pinnedID: rig.app.configStore.config.controllerDeviceID)
    }

    /// The picker's rows come from the live service: Automatic, then both
    /// pads most recent first, the couch marked as the one in use. Choosing
    /// the desk row stores its pin, which moves the slot and survives a
    /// reload; switching the desk pad off keeps it as a "not connected" row.
    func testPickingAPadPinsTheSlotPersistsTheChoiceAndShowsItAwayWhenOff() async throws {
        let rig = await makeRig()

        var rows = pickerRows(rig)
        XCTAssertEqual(rows.map(\.pin), [nil, rig.couch.id, rig.desk.id])
        XCTAssertEqual(rows.first(where: \.isInSlot)?.pin, rig.couch.id)

        let deskRow = try XCTUnwrap(rows.first { $0.pin == rig.desk.id })
        rig.app.configStore.config.controllerDeviceID = deskRow.pin
        await settle(until: rig.controller.active == rig.desk)
        XCTAssertEqual(pickerRows(rig).first(where: \.isInSlot)?.pin, rig.desk.id)

        rig.app.configStore.save()
        XCTAssertEqual(env.makeConfigStore().config.controllerDeviceID, rig.desk.id,
                       "the pin is written to config.json")

        rig.controller.simulateDisconnect(rig.desk.id)
        await settle(until: rig.app.status == .noController)
        rows = pickerRows(rig)
        XCTAssertEqual(rows, [
            ControllerPickerRow(pin: nil, title: "Automatic", isConnected: true, isInSlot: false),
            ControllerPickerRow(pin: rig.couch.id, title: "Couch Pad", isConnected: true, isInSlot: false),
            ControllerPickerRow(pin: rig.desk.id, title: "Desk Pad — not connected",
                                isConnected: false, isInSlot: false),
        ])
        XCTAssertNil(rig.controller.active, "the couch pad does not take a pinned slot")
        withExtendedLifetime(rig.app) {}
    }

    private func lastLight(_ rig: Rig, on id: String) -> ControllerOutput? {
        rig.controller.recordedWrites.last {
            guard $0.controllerID == id, case .light = $0.output else { return false }
            return true
        }?.output
    }
}
