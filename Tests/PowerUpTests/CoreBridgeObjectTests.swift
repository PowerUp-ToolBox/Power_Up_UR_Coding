import XCTest
@testable import PowerUp

/// The app-side wrappers over the bridge objects (`CoreBridgeHarness.swift`,
/// `CoreBridgeSession.swift`, `CoreBridgeACP.swift`,
/// `CoreBridgeListener.swift`): the app's own types go in, the app's own
/// types come out, and the state lives in the core object between calls.
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

    // MARK: ACP adapter

    func testTheACPWrapperSpeaksTheAppsTypes() {
        let machine = CoreBridge.ACPStateMachine()
        XCTAssertEqual(machine.snapshot, .stopped)
        let configuration = HarnessConfiguration(projectDir: URL(fileURLWithPath: "/work/app", isDirectory: true),
                                                 model: "default", permissionMode: "default", effort: "default",
                                                 resumeSessionID: nil, binaryPathOverride: nil,
                                                 agentCommand: ["/bin/agent", "acp"])
        XCTAssertEqual(machine.start(configuration), [
            .publish(.init(state: .starting, sessionID: nil, modelName: nil, totalTokens: 0)),
            .spawn(generation: 1, executable: "/bin/agent", arguments: ["acp"], projectDir: "/work/app")
        ])
        XCTAssertEqual(machine.generation, 1)
        let spawned = machine.spawned(generation: 1)
        XCTAssertEqual(spawned.count, 2)
        XCTAssertEqual(spawned.last, .armStartWatchdog(generation: 1, seconds: 30))

        _ = machine.stdoutLine(generation: 1, line: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        XCTAssertEqual(machine.stdoutLine(generation: 1, line: Data(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#.utf8)), [
            .publish(.init(state: .ready, sessionID: "s1", modelName: nil, totalTokens: 0)),
            .emit(.sessionReady(sessionID: "s1", model: "acp"))
        ])
        XCTAssertEqual(machine.terminated(generation: 1, exitCode: 3, stderrTail: "boom"), [
            .publish(.init(state: .stopped, sessionID: nil, modelName: nil, totalTokens: 0)),
            .emit(.runtimeError("boom")),
            .emit(.ended(exitCode: 3))
        ])
        XCTAssertEqual(machine.send("Hi"), [.emit(.runtimeError("Can't send that — the agent session isn't running."))])
    }

    func testTheACPStaticsSpeakTheAppsTypes() {
        XCTAssertEqual(CoreBridge.acpPermissionChoice(options: [("aa", "allow_always"), ("ao", "allow_once")], allow: true),
                       "ao")
        XCTAssertEqual(CoreBridge.acpAgentLaunch(agent: "custom", customCommand: "/x/agent acp"),
                       .init(program: .command("/x/agent"), arguments: ["acp"]))
        XCTAssertNil(CoreBridge.acpAgentLaunch(agent: "custom", customCommand: " "))
        let scrub = CoreBridge.acpEnvironmentScrub
        XCTAssertTrue(scrub.scrubs("CLAUDE_CODE_ENTRYPOINT"))
        XCTAssertFalse(scrub.scrubs("CLAUDE_CODE"))
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

    // MARK: Listener policy

    /// A masked client text frame (a zero key, so the payload reads as
    /// written).
    private func clientText(_ text: String) -> Data {
        Data([0x81, 0x80 | UInt8(text.utf8.count), 0, 0, 0, 0]) + Data(text.utf8)
    }

    func testTheListenerWrapperSpeaksTheAppsTypes() throws {
        let policy = CoreBridge.ListenerPolicy()
        XCTAssertEqual(policy.status, .stopped)
        XCTAssertEqual(policy.start(port: 48738, token: "secret"), [.listen(generation: 2, port: 48738)])
        XCTAssertEqual(policy.bindReady(generation: 2), [.publish(.init(isRunning: true, lastError: nil))])
        XCTAssertEqual(policy.accepted(generation: 2), [.admit(connection: 1), .armIdleDeadline(connection: 1, seconds: 15)])

        let body = #"{"hook_event_name":"Stop","last_assistant_message":"Done.","session_id":"s1","cwd":"/work"}"#
        let post = "POST /event HTTP/1.1\r\nX-PowerUp-Token: secret\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let hook = RemoteHookEvent(kind: .stop, text: "Done.", sessionID: "s1", cwd: "/work")
        XCTAssertEqual(policy.received(connection: 1, bytes: Data(post.utf8)), [
            .send(connection: 1, bytes: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)),
            .close(connection: 1),
            .deliverHook(generation: 2, hook)
        ])
        XCTAssertEqual(policy.closed(connection: 1), [.cancel(connection: 1)])

        _ = policy.accepted(generation: 2)
        let upgrade = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        let effects = policy.received(connection: 2,
                                      bytes: Data(upgrade.utf8) + clientText(#"{"type":"hello","token":"secret"}"#))
        XCTAssertEqual(effects.last, .welcome(connection: 2))
        XCTAssertEqual(policy.authenticatedCount, 1)
        XCTAssertEqual(policy.connectionCount, 1)

        let snapshot: [CoreBridge.ServerMessage] = [
            .status(.idle),
            .session(.init(model: "default", liveModel: nil, effort: "high", permissionMode: "plan",
                           controlMode: "local", sessionID: nil, costUSD: 0, tokens: 0)),
        ]
        let welcome = policy.welcome(connection: 2, appVersion: "1.0", snapshot: snapshot)
        let texts = welcome.map { effect -> String in
            guard case .send(2, let bytes) = effect, bytes.count > 2 else {
                XCTFail("not a send to the client: \(effect)")
                return ""
            }
            return String(decoding: bytes.dropFirst(2), as: UTF8.self)
        }
        XCTAssertEqual(texts, [
            #"{"type":"welcome","protocol":0,"app":"PowerUp","version":"1.0"}"#,
            #"{"type":"status","status":"idle"}"#,
            #"{"type":"session","model":"default","effort":"high","permissionMode":"plan","controlMode":"local","costUSD":0}"#,
        ])
        XCTAssertEqual(policy.received(connection: 2, bytes: clientText(#"{"type":"intent","intent":"sendPrompt","text":" hi "}"#)),
                       [.deliverIntent(generation: 2, .sendPrompt("hi"))])
        let entry = TranscriptEntry(id: try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")), kind: .user,
                                    text: "hi", date: Date(timeIntervalSince1970: 2))
        let text = #"{"type":"transcript","entry":{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","kind":"user","text":"hi","date":2}}"#
        XCTAssertEqual(CoreBridge.protocolEncode(.transcript(entry)), text)
        XCTAssertEqual(policy.broadcast(.transcript(entry)),
                       [.broadcast(connections: [2], bytes: try XCTUnwrap(CoreBridge.encodeText(Data(text.utf8))))])
        XCTAssertEqual(policy.deadlineFired(connection: 2), [], "an authenticated client is spared")

        XCTAssertEqual(policy.bindFailed(generation: 2, error: .addressInUse), [
            .publish(.init(isRunning: false,
                           lastError: "Port 48738 is already in use — pick a different port in Settings → Remote.")),
            .stopListening,
            .cancel(connection: 2),
            .scheduleBindRetry(generation: 3, seconds: 2),
        ])
        XCTAssertEqual(policy.generation, 3)
        _ = policy.stop()
        XCTAssertEqual(policy.retryFired(generation: 3), [], "a stop invalidates the retry")
    }

    func testTheProtocolWrappersSpeakTheAppsTypes() {
        XCTAssertEqual(CoreBridge.clientMessage(Data(#"{"type":"hello","token":"t"}"#.utf8)), .success(.hello(token: "t")))
        XCTAssertEqual(CoreBridge.clientMessage(Data(#"{"type":"intent","intent":"approve"}"#.utf8)),
                       .success(.intent(.approve)))
        XCTAssertEqual(CoreBridge.clientMessage(Data(#"{"type":"hello"}"#.utf8)),
                       .failure(.init(code: "bad_hello", message: #"hello must carry a non-empty "token"."#)))
        XCTAssertEqual(CoreBridge.protocolIntent(name: "cycleFocus", text: nil), .cycleFocus)
        XCTAssertNil(CoreBridge.protocolIntent(name: "setPermissionMode", text: "bypassPermissions"))
        XCTAssertEqual(CoreBridge.handshake(Data("GET /ws HTTP/1.1\n\n".utf8)),
                       .refuse(method: "GET", path: "/ws", status: 400, reason: "Bad Request"))
        XCTAssertEqual(CoreBridge.acceptKey(forClientKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertEqual(CoreBridge.decodeFrames(clientText("hi") + Data([0x81]), maxPayload: 1024),
                       .frames([.init(opcode: .text, payload: Data("hi".utf8))], consumed: 8))
        XCTAssertEqual(CoreBridge.decodeFrames(clientText("hi"), maxPayload: 1), .violation)
        XCTAssertEqual(CoreBridge.encodeFrame(opcode: .ping, payload: Data()), Data([0x89, 0x00]))
        XCTAssertEqual(CoreBridge.encodeClose(code: 1013), Data([0x88, 0x02, 0x03, 0xF5]))
        XCTAssertEqual(CoreBridge.protocolEncode(.error(code: "auth_failed", message: "a/b")),
                       #"{"type":"error","code":"auth_failed","message":"a\/b"}"#)
    }

    func testTheListenerLimitsFallbackIsTheCores() {
        XCTAssertEqual(CoreBridge.listenerLimits, .fallback)
        XCTAssertEqual(CoreBridge.listenerLimits.receiveChunkBytes, 32 * 1024)
    }
}
