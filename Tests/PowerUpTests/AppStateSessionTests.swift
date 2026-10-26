import XCTest
@testable import PowerUp

/// Session rules driven through the AppState seam with a scripted harness
/// (#111): AppState is built with a `FakeHarnessAdapter`, the scenario is
/// played through public entry points (controller callbacks, intents, events
/// the fake emits), and the assertions read published state and what the
/// fake recorded. Everything is synchronous — no sleeps, no expectations.
@MainActor
final class AppStateSessionTests: XCTestCase {

    private var env: AppStateTestEnvironment!

    override func setUpWithError() throws {
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        // TTS is real in the seam; keep announcements ("Approval needed") and
        // spoken replies off so a test run makes no sound.
        config.ttsEnabled = false
        // Pin the mapping these scenarios press, rather than lean on defaults.
        config.mapping[.cross] = .approve
        config.mapping[.circle] = .reject
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
    }

    // MARK: Press-to-approve

    func testPadPressMappedToApproveAnswersThePendingPermission() {
        let controller = ControllerService()
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, harness: harness)

        harness.queue(.permissionRequest(id: "perm-1", name: "Edit",
                                         kind: "edit", detail: "Sources/main.swift"))
        harness.emitNext()
        XCTAssertEqual(app.pendingPermission?.id, "perm-1")
        XCTAssertEqual(app.pendingPermission?.isDestructive, false)

        controller.onButtonDown?(.cross)

        XCTAssertEqual(harness.calls, [.respondToPermission(id: "perm-1", allow: true)])
        XCTAssertNil(app.pendingPermission)
        XCTAssertEqual(app.transcript.last?.text, "Approved.")
    }

    func testPadPressMappedToRejectDeniesThePendingPermission() {
        let controller = ControllerService()
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, harness: harness)

        harness.emit(.permissionRequest(id: "perm-2", name: "Bash",
                                        kind: "execute", detail: "swift test"))
        controller.onButtonDown?(.circle)

        XCTAssertEqual(harness.calls, [.respondToPermission(id: "perm-2", allow: false)])
        XCTAssertNil(app.pendingPermission)
        XCTAssertEqual(app.transcript.last?.text, "Denied.")
    }

    func testDestructivePermissionNeedsTwoApprovePresses() {
        let controller = ControllerService()
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, harness: harness)

        harness.emit(.permissionRequest(id: "perm-3", name: "Bash",
                                        kind: "execute", detail: "git reset --hard HEAD~3"))
        XCTAssertEqual(app.pendingPermission?.isDestructive, true)

        controller.onButtonDown?(.cross)
        XCTAssertTrue(harness.calls.isEmpty, "the first press only arms a destructive request")
        XCTAssertEqual(app.pendingPermission?.armed, true)

        controller.onButtonDown?(.cross)
        XCTAssertEqual(harness.calls, [.respondToPermission(id: "perm-3", allow: true)])
        XCTAssertNil(app.pendingPermission)
    }

    func testCompletedTurnClearsAnUnansweredPermission() {
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(harness: harness)

        harness.queue(.permissionRequest(id: "perm-4", name: "Edit", kind: "edit", detail: ""),
                      .turnCompleted(resultText: "done", costUSD: nil, isError: false, detail: "success"))
        harness.emitAll()

        XCTAssertNil(app.pendingPermission)
        XCTAssertTrue(harness.calls.isEmpty, "nothing was answered on the user's behalf")
    }

    // MARK: The fake itself

    func testFakeEmitsSynchronouslyInQueueOrder() {
        let harness = FakeHarnessAdapter()
        var received: [HarnessEvent] = []
        harness.onHarnessEvent = { received.append($0) }

        harness.queue(.sessionReady(sessionID: "s-1", model: "sonnet"), .replyDelta("hi"))
        XCTAssertTrue(received.isEmpty, "queued events wait for the test")

        XCTAssertEqual(harness.emitNext(), .sessionReady(sessionID: "s-1", model: "sonnet"))
        XCTAssertEqual(received, [.sessionReady(sessionID: "s-1", model: "sonnet")])
        XCTAssertEqual(harness.sessionID, "s-1")
        XCTAssertEqual(harness.modelName, "sonnet")

        harness.emitAll()
        XCTAssertEqual(received.last, .replyDelta("hi"))
        XCTAssertNil(harness.emitNext())
    }

    func testFakeRecordsEveryCallAndMirrorsTheLifecycle() {
        let harness = FakeHarnessAdapter()
        let configuration = HarnessConfiguration(projectDir: URL(fileURLWithPath: "/tmp/p", isDirectory: true),
                                                 model: "default", permissionMode: "default",
                                                 effort: "default", resumeSessionID: nil,
                                                 binaryPathOverride: nil)

        harness.start(configuration)
        XCTAssertEqual(harness.state, .starting)
        harness.emit(.sessionReady(sessionID: "s-2", model: "opus"))
        XCTAssertEqual(harness.state, .ready)
        harness.send("hello")
        XCTAssertEqual(harness.state, .working)
        harness.setModel("haiku")
        harness.setPermissionMode("plan")
        harness.interrupt()
        harness.respondToPermission(id: "p", allow: true)
        harness.emit(.turnCompleted(resultText: nil, costUSD: 0.25, isError: false, detail: "success"))
        XCTAssertEqual(harness.state, .ready)
        XCTAssertEqual(harness.totalCostUSD, 0.25)
        harness.stop()
        XCTAssertEqual(harness.state, .stopped)

        XCTAssertEqual(harness.calls, [
            .start(configuration), .send("hello"), .setModel("haiku"),
            .setPermissionMode("plan"), .interrupt,
            .respondToPermission(id: "p", allow: true), .stop,
        ])
    }
}
