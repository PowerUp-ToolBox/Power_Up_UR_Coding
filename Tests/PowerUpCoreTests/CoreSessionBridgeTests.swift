import XCTest
import PowerUpCore

/// The session half of the bridge (slice 2.3): `CoreSession` keeps the
/// session rules' state between calls and answers with effects, and the
/// status, classifier and cycle functions answer through the generated
/// functions.
final class CoreSessionBridgeTests: XCTestCase {

    private let settings = CoreSessionSettings(
        harnessKind: "claude", acpAgent: "opencode", acpCustomCommand: "", controlMode: "builtin",
        model: "default", modelCycle: [], effort: "default", permissionMode: "acceptEdits",
        projectDir: "/work/app", lastSessionId: nil, sessionIdsByProject: ["/work/app": "s-1"],
        recentProjectDirs: ["/work/app"], claudePath: nil, remoteAutoSubmit: true)

    private func context(claude state: CoreHarnessState, sessionID: String? = nil) -> CoreSessionContext {
        CoreSessionContext(settings: settings,
                           claude: CoreHarnessSnapshot(state: state, sessionId: sessionID, modelName: nil,
                                                       supportsEffort: true),
                           acp: nil, acpAgentCommand: nil, now: 800_000_000)
    }

    func testAStartResumesTheFoldersOwnSession() throws {
        let session = try CoreSession(initial: settings)
        let effects = try session.startSessionIfNeeded(context: context(claude: .stopped))
        XCTAssertTrue(effects.contains(.startHarness(harness: .claude, configuration: CoreHarnessConfiguration(
            projectDir: "/work/app", model: "default", permissionMode: "acceptEdits", effort: "default",
            resumeSessionId: "s-1", binaryPathOverride: nil, agentCommand: nil))), "\(effects)")
        // A session that is already running is left alone.
        XCTAssertFalse(try session.startSessionIfNeeded(context: context(claude: .ready, sessionID: "s-1"))
            .contains { if case .startHarness = $0 { return true } else { return false } })
    }

    /// The machine keeps state between calls: a destructive permission
    /// request stays pending until it is answered twice.
    func testAPendingPermissionLivesInTheObject() throws {
        let session = try CoreSession(initial: settings)
        let ready = context(claude: .ready, sessionID: "s-1")
        let request = CoreHarnessEvent.permissionRequest(id: "p1", name: "Bash", kind: "execute", detail: "rm -rf build")
        _ = try session.harnessEvent(context: ready, from: .claude, event: request)
        XCTAssertEqual(try session.pendingPermission(),
                       CorePendingPermission(id: "p1", name: "Bash", detail: "rm -rf build", isDestructive: true, armed: false))
        let first = try session.handleIntent(context: ready, intent: .approve)
        XCTAssertFalse(first.contains(.answerPermission(harness: .claude, id: "p1", allow: true)))
        XCTAssertEqual(try session.pendingPermission()?.armed, true)
        let second = try session.handleIntent(context: ready, intent: .approve)
        XCTAssertTrue(second.contains(.answerPermission(harness: .claude, id: "p1", allow: true)), "\(second)")
        XCTAssertNil(try session.pendingPermission())
    }

    func testTheStatusAndCycleFunctionsAnswer() throws {
        XCTAssertEqual(try derivedStatus(controllerConnected: true, isPttActive: false, isSpeaking: true, isWorking: true),
                       .speaking)
        XCTAssertFalse(try derivedIsWorking(harnessState: .ready, isRemoteMode: false, remoteTurnActive: true))
        XCTAssertEqual(try liveRemoteTurns(turns: ["a": 0, "b": 950], now: 1000, expiry: 900), ["b": 950])
        XCTAssertTrue(try remoteTurnIsActive(turns: ["a": 0], focus: nil))
        XCTAssertEqual(try remoteTurnExpirySeconds(), 900)
        XCTAssertEqual(try modelChipLabel(configured: "opus", reported: "claude-sonnet"), "opus")
        XCTAssertTrue(try isDestructive(kind: "DELETE", title: "", detail: ""))
        XCTAssertEqual(try effortCycle(), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(try permissionModeCycle(), ["acceptEdits", "plan", "default"])
        XCTAssertEqual(try defaultModelCycle(), ["sonnet", "opus", "haiku", "fable"])
        XCTAssertEqual(try effortDisplayName(effort: "xhigh"), "Extra High")
        XCTAssertEqual(try acpAgentDisplayName(agent: "claudeBridge"), "Claude Code (ACP bridge)")
        XCTAssertTrue(try isRemoteMode(controlMode: "remote"))
        XCTAssertEqual(try harnessKindFromSetting(raw: "acp"), .acp)
    }
}
