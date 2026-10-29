import XCTest
@testable import PowerUp

/// The two seams remote-mode scenarios run on (#118): an injected
/// `RemoteInjector` replaces every real delivery route of
/// `RemoteControlService`, and a `RemoteTurnClock` drives remote-turn expiry
/// by advancing time instead of waiting.
@MainActor
final class RemoteSeamTests: XCTestCase {

    private var env: AppStateTestEnvironment!

    override func setUp() async throws {
        var config = AppConfig.defaultConfig()
        config.ttsEnabled = false
        config.controlMode = "remote"
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDown() async throws {
        env.tearDown()
        env = nil
    }

    // MARK: Injector

    func testAnInjectedInjectorReplacesEveryDeliveryRoute() {
        let injector = RecordingInjector()
        let service = RemoteControlService(injector: injector)

        // cmux, frontmost-app typing and named-app typing all go to the
        // injector; none of them reaches a subprocess or a posted key event.
        for kind in ["cmux", "frontmost", "app"] {
            var config = AppConfig.defaultConfig()
            config.remoteTargetKind = kind
            config.remoteAppBundleID = "com.example.terminal"
            var results: [String?] = []

            service.sendText("first line\nsecond line", submit: true, config: config) { results.append($0) }
            service.sendKey(.escape, config: config) { results.append($0) }

            XCTAssertEqual(injector.calls, [.text("first line second line", submit: true), .key(.escape)],
                           "route \(kind)")
            XCTAssertEqual(results, [nil, nil], "route \(kind)")
            injector.clearCalls()
        }
    }

    func testTheInjectorReceivesTextWithLineBreaksAlreadyFlattened() throws {
        let injector = RecordingInjector()
        let service = RemoteControlService(injector: injector)
        let text = "one\r\ntwo\u{2028}three"

        service.sendText(text, submit: false, config: AppConfig.defaultConfig()) { _ in }

        XCTAssertEqual(injector.calls, [.text(try XCTUnwrap(CoreBridge.flattenLineBreaks(text)), submit: false)])
        XCTAssertEqual(injector.calls, [.text("one two three", submit: false)])
    }

    func testAnInjectorFailureReachesTheCompletion() {
        let injector = RecordingInjector()
        injector.failure = "cmux is not running"
        let service = RemoteControlService(injector: injector)
        var result: String?

        service.sendKey(.enter, config: AppConfig.defaultConfig()) { result = $0 }

        XCTAssertEqual(result, "cmux is not running")
    }

    func testTheTestEnvironmentsRemoteModeTypesIntoItsRecordingInjector() {
        let app = env.makeAppState(harness: FakeHarnessAdapter())
        XCTAssertTrue(app.isRemoteMode)

        app.sendUserText("Run the tests")
        app.interruptClaude()

        XCTAssertEqual(env.injector.calls, [.text("Run the tests", submit: true), .key(.escape)])
        withExtendedLifetime(app) {}
    }

    func testARemoteFailureReportedByTheInjectorIsShownAsAnError() {
        env.injector.failure = "Couldn't reach cmux."
        let app = env.makeAppState(harness: FakeHarnessAdapter())

        app.sendUserText("Hello")

        XCTAssertEqual(app.transcript.last?.kind, .error)
        XCTAssertEqual(app.transcript.last?.text, "Couldn't reach cmux.")
    }

    // MARK: Clock

    func testTheManualClockRunsActionsOnlyWhenTheyFallDueInDueOrder() {
        let clock = ManualRemoteTurnClock()
        let start = clock.now
        var ran: [String] = []
        clock.schedule(after: 20) { ran.append("b@\(clock.now.timeIntervalSince(start))") }
        clock.schedule(after: 10) { ran.append("a@\(clock.now.timeIntervalSince(start))") }
        clock.schedule(after: 20) { ran.append("c@\(clock.now.timeIntervalSince(start))") }

        clock.advance(by: 9)
        XCTAssertEqual(ran, [])
        XCTAssertEqual(clock.now.timeIntervalSince(start), 9)

        clock.advance(by: 30)
        XCTAssertEqual(ran, ["a@10.0", "b@20.0", "c@20.0"])
        XCTAssertEqual(clock.now.timeIntervalSince(start), 39)
        XCTAssertEqual(clock.pendingActionCount, 0)
    }

    func testARemoteTurnExpiresOnTheInjectedClockWithoutWaiting() {
        let clock = ManualRemoteTurnClock()
        let listener = RemoteListener()
        let app = env.makeAppState(harness: FakeHarnessAdapter(), listener: listener, clock: clock)

        listener.onEvent?(RemoteHookEvent(kind: .userPromptSubmit, text: "Go", sessionID: "s1", cwd: nil))
        XCTAssertTrue(app.remoteTurnActive)
        XCTAssertEqual(clock.pendingActionCount, 1, "starting a turn arms one expiry check on the clock")

        clock.advance(by: 15 * 60 - 1)
        XCTAssertTrue(app.remoteTurnActive)

        clock.advance(by: 2)
        XCTAssertFalse(app.remoteTurnActive)
        XCTAssertEqual(app.status, .noController)
        withExtendedLifetime((app, listener)) {}
    }
}
