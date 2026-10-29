import XCTest
@testable import PowerUp

/// The app-side wrappers over the slice 2.3 bridge objects
/// (`CoreBridgeHarness.swift`, `CoreBridgeSession.swift`): the app's own
/// types go in, the app's own types come out, and the state lives in the
/// core object between calls.
@MainActor
final class CoreBridgeObjectTests: XCTestCase {

    // MARK: Claude adapter

    func testTheAdapterWrapperSpeaksTheAppsTypes() {
        let adapter = CoreBridge.ClaudeAdapter(requestIDPrefix: "R")
        let configuration = HarnessConfiguration(projectDir: URL(fileURLWithPath: "/work/app", isDirectory: true),
                                                 model: "opus", permissionMode: "plan", effort: "max",
                                                 resumeSessionID: "s-1", binaryPathOverride: nil)
        XCTAssertEqual(adapter.start(configuration), [
            .publish(.init(state: .starting, sessionID: "s-1", modelName: nil, totalCostUSD: 0)),
            .resolveBinary(generation: 1, binaryPathOverride: nil)
        ])
        XCTAssertEqual(adapter.generation, 1)
        guard case .spawn(1, "/bin/claude", let arguments, "/work/app")? =
                adapter.binaryResolved(generation: 1, path: "/bin/claude").first else {
            return XCTFail("no spawn of the resolved binary in the project folder")
        }
        XCTAssertEqual(arguments.suffix(6), ["--permission-mode", "plan", "--effort", "max", "--resume", "s-1"])
        XCTAssertEqual(adapter.spawned(generation: 1), [])

        let init_ = CoreBridge.claudeEvents(fromLine: Data(#"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-opus"}"#.utf8))
        XCTAssertEqual(init_, [.ready(sessionID: "s-1", model: "claude-opus")])
        XCTAssertEqual(adapter.stdoutEvent(generation: 1, event: init_[0]), [
            .publish(.init(state: .ready, sessionID: "s-1", modelName: "claude-opus", totalCostUSD: 0)),
            .emit(.sessionReady(sessionID: "s-1", model: "claude-opus"))
        ])
        XCTAssertEqual(adapter.send("Hi", processRunning: false),
                       [.emit(.runtimeError("Can't send that — the Claude session isn't running."))])
        XCTAssertEqual(adapter.stop(), [
            .closeStdin,
            .publish(.init(state: .stopped, sessionID: "s-1", modelName: "claude-opus", totalCostUSD: 0)),
            .terminateAfterGrace(seconds: 2)
        ])
        XCTAssertEqual(adapter.terminated(generation: 1, exitCode: 0, clean: true, stderrTail: ""), [
            .publish(.init(state: .stopped, sessionID: nil, modelName: "claude-opus", totalCostUSD: 0)),
            .emit(.ended(exitCode: 0))
        ])
        XCTAssertEqual(adapter.snapshot, .init(state: .stopped, sessionID: nil, modelName: "claude-opus", totalCostUSD: 0))
    }

    func testEveryClaudeEventNormalizesThroughTheCore() {
        let pairs: [(ClaudeEvent, HarnessEvent)] = [
            (.ready(sessionID: "s", model: "m"), .sessionReady(sessionID: "s", model: "m")),
            (.textDelta("He"), .replyDelta("He")),
            (.assistantMessage("Hello"), .reply("Hello")),
            (.toolUse(name: "Edit", detail: "a.txt"), .toolUse(name: "Edit", detail: "a.txt")),
            (.turnCompleted(resultText: nil, costUSD: 0.5, isError: true, subtype: "error_max_turns"),
             .turnCompleted(resultText: nil, costUSD: 0.5, isError: true, detail: "error_max_turns")),
            (.controlResult(action: "set_model", ok: true, detail: "", value: "sonnet"),
             .controlResult(action: "set_model", ok: true, detail: "", value: "sonnet")),
            (.processError("boom"), .runtimeError("boom")),
            (.terminated(exitCode: 2), .ended(exitCode: 2))
        ]
        for (claude, harness) in pairs {
            XCTAssertEqual(CoreBridge.harnessEvent(from: claude), harness)
        }
    }

    // MARK: Session

    private func context(_ config: AppConfig, claude: HarnessState = .stopped,
                         sessionID: String? = nil) -> CoreBridge.SessionContext {
        CoreBridge.SessionContext(config: config,
                                  claude: .init(state: claude, sessionID: sessionID, modelName: nil, supportsEffort: true),
                                  acp: nil, acpAgentCommand: nil, now: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    func testTheSessionWrapperStartsTheFoldersSession() {
        var config = AppConfig.defaultConfig()
        config.projectDir = "/work/app"
        config.sessionIDsByProject = ["/work/app": "s-1"]
        let session = CoreBridge.Session(initial: config)
        let effects = session.startSessionIfNeeded(context: context(config))
        let expected = HarnessConfiguration(projectDir: URL(fileURLWithPath: "/work/app", isDirectory: true),
                                            model: config.model, permissionMode: config.permissionMode,
                                            effort: config.effort, resumeSessionID: "s-1",
                                            binaryPathOverride: config.claudePath)
        XCTAssertTrue(effects.contains(.startHarness(.claude, expected)), "\(effects)")
    }

    func testAPendingPermissionComesBackAsTheAppsStruct() {
        let config = AppConfig.defaultConfig()
        let session = CoreBridge.Session(initial: config)
        let ready = context(config, claude: .ready, sessionID: "s-1")
        let effects = session.harnessEvent(context: ready, from: .claude,
                                           event: .permissionRequest(id: "p1", name: "Bash", kind: "execute",
                                                                     detail: "git push --force"))
        let pending = AppState.PendingPermission(id: "p1", name: "Bash", detail: "git push --force", isDestructive: true)
        XCTAssertTrue(effects.contains(.pendingPermissionChanged(pending)), "\(effects)")
        XCTAssertEqual(session.pendingPermission, pending)
        XCTAssertFalse(session.remoteTurnActive)
        XCTAssertNil(session.remoteFocus)
        XCTAssertNil(session.remoteFocusLabel)
        // An event from the adapter that is not selected is dropped whole.
        XCTAssertEqual(session.harnessEvent(context: ready, from: .acp, event: .reply("late")), [])
    }

    func testHooksArePlacedByTheInjectedPlacer() {
        var config = AppConfig.defaultConfig()
        config.controlMode = "remote"
        config.projectDir = "/work/app"
        let session = CoreBridge.Session(initial: config)
        var placed: [String] = []
        let place = { (path: String) -> CoreBridge.PlacedPath in
            placed.append(path)
            let parts = path.split(separator: "/").map(String.init)
            return CoreBridge.PlacedPath(components: ["/"] + parts, standardized: path, name: parts.last ?? "")
        }
        let hook = RemoteHookEvent(kind: .stop, text: "Done.", sessionID: "r-1", cwd: "/work/app/sub")
        let effects = session.hookEvent(context: context(config), hook: hook, place: place)
        XCTAssertEqual(placed, ["/work/app/sub", "/work/app"])
        XCTAssertTrue(effects.contains(.appendTranscript(.assistant, "[sub] Done.")), "\(effects)")
    }

    func testPlacingAPathStandardizesIt() {
        let place = CoreBridge.PlacedPath.place("/tmp/../usr/./bin/")
        XCTAssertEqual(place.standardized, "/usr/bin")
        XCTAssertEqual(place.name, "bin")
        XCTAssertEqual(place.components.first, "/")
    }
}
