import XCTest
@testable import PowerUp

// MARK: - Pure logic

final class ACPAdapterUnitTests: XCTestCase {

    func testCustomCommandSplitsOnSpaces() {
        var config = AppConfig.defaultConfig()
        config.acpAgent = "custom"
        config.acpCustomCommand = "/usr/local/bin/agent acp --flag"
        XCTAssertEqual(ACPAdapter.agentCommand(for: config), ["/usr/local/bin/agent", "acp", "--flag"])

        config.acpCustomCommand = "   "
        XCTAssertNil(ACPAdapter.agentCommand(for: config))
    }

    func testUnknownAgentResolvesToNil() {
        var config = AppConfig.defaultConfig()
        config.acpAgent = "warp-drive"
        XCTAssertNil(ACPAdapter.agentCommand(for: config))
    }

    func testAgentEnvironmentStripsClaudeNestingMarkers() {
        // Verified live: the Claude bridge refuses to run when these are set.
        let base = ["CLAUDECODE": "1",
                    "CLAUDE_CODE_SESSION_ID": "abc",
                    "CLAUDE_CODE_ENTRYPOINT": "cli",
                    "CLAUDE_PID": "42",
                    "HOME": "/Users/x",
                    "PATH": "/usr/bin"]
        let env = ACPAdapter.agentEnvironment(from: base)
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SESSION_ID"])
        XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(env["CLAUDE_PID"])
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertTrue(env["PATH"]!.contains("/opt/homebrew/bin"), "install locations join PATH")
        XCTAssertTrue(env["PATH"]!.hasPrefix("/usr/bin"))
    }

    func testPermissionChoicePrefersOnceVariants() {
        let options: [(id: String, kind: String)] = [
            ("aa", "allow_always"), ("ao", "allow_once"),
            ("ra", "reject_always"), ("ro", "reject_once"),
        ]
        // A controller press must never silently grant or deny "always".
        XCTAssertEqual(ACPAdapter.permissionChoice(options: options, allow: true), "ao")
        XCTAssertEqual(ACPAdapter.permissionChoice(options: options, allow: false), "ro")
    }

    func testPermissionChoiceFallsBackAndCanFail() {
        XCTAssertEqual(ACPAdapter.permissionChoice(options: [("aa", "allow_always")], allow: true), "aa")
        XCTAssertNil(ACPAdapter.permissionChoice(options: [("aa", "allow_always")], allow: false))
        XCTAssertNil(ACPAdapter.permissionChoice(options: [], allow: true))
    }

    func testHarnessConfigDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.harnessKind, "claude", "the built-in adapter stays the default")
        XCTAssertEqual(decoded.acpAgent, "opencode")
        let bogus = try JSONDecoder().decode(AppConfig.self,
                                             from: Data(#"{"harnessKind":"telepathy","acpAgent":"warp"}"#.utf8))
        XCTAssertEqual(bogus.harnessKind, "claude")
        XCTAssertEqual(bogus.acpAgent, "opencode")
    }
}

// MARK: - Integration against a scripted mock agent

/// Runs the real adapter against a python mock speaking ACP over stdio —
/// initialize, session/new, streamed updates, a permission request, and
/// set_model, without any real harness or network.
@MainActor
final class ACPAdapterIntegrationTests: XCTestCase {

    private var adapter: ACPAdapter!
    private var events: [HarnessEvent] = []
    private var scriptURL: URL!

    private static let python = "/usr/bin/python3"

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.python),
                          "python3 unavailable")
        scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-acp-\(UUID().uuidString).py")
        try Self.mockAgentScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        adapter = ACPAdapter()
        events = []
        adapter.onHarnessEvent = { [weak self] event in self?.events.append(event) }
    }

    override func tearDown() async throws {
        adapter?.stop()
        adapter = nil
        if let scriptURL { try? FileManager.default.removeItem(at: scriptURL) }
    }

    private func startAdapter() {
        adapter.start(HarnessConfiguration(
            projectDir: URL(fileURLWithPath: "/tmp", isDirectory: true),
            model: "default", permissionMode: "default", effort: "default",
            resumeSessionID: nil, binaryPathOverride: nil,
            agentCommand: [Self.python, scriptURL.path]))
    }

    private func waitForEvent(timeout: TimeInterval = 10,
                              where predicate: @escaping (HarnessEvent) -> Bool) async throws {
        var elapsed: TimeInterval = 0
        while elapsed < timeout {
            if events.contains(where: predicate) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 0.1
        }
        XCTFail("timed out; events so far: \(events)")
    }

    func testStartupHandshakeEmitsSessionReady() async throws {
        startAdapter()
        try await waitForEvent { if case .sessionReady("mock-session", "mock/model-1") = $0 { return true }; return false }
        XCTAssertEqual(adapter.state, .ready)
        XCTAssertEqual(adapter.sessionID, "mock-session")
        XCTAssertEqual(adapter.modelName, "mock/model-1")
    }

    func testPromptStreamsToolsPermissionAndCompletion() async throws {
        startAdapter()
        try await waitForEvent { if case .sessionReady = $0 { return true }; return false }

        adapter.send("do the thing")
        XCTAssertEqual(adapter.state, .working)

        // The mock streams a thought (must be skipped), a chunk, a tool call,
        // then asks permission.
        try await waitForEvent { if case .permissionRequest = $0 { return true }; return false }
        XCTAssertTrue(events.contains { if case .replyDelta("Working. ") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolUse("Edit File", "a.swift") = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .replyDelta("thinking") = $0 { return true }; return false },
                       "thought chunks must not leak into the reply stream")

        guard case .permissionRequest(let id, let name, let kind, _)? =
                events.first(where: { if case .permissionRequest = $0 { return true }; return false }) else {
            return XCTFail("no permission request captured")
        }
        XCTAssertEqual(name, "Edit a.swift")
        XCTAssertEqual(kind, "edit", "the harness's tool kind must reach the classifier")

        // Approve → the mock reports which option we chose, then ends the turn.
        adapter.respondToPermission(id: id, allow: true)
        try await waitForEvent { if case .turnCompleted = $0 { return true }; return false }

        guard case .turnCompleted(let text, let cost, let isError, let detail)? =
                events.last(where: { if case .turnCompleted = $0 { return true }; return false }) else {
            return XCTFail("no completion")
        }
        XCTAssertEqual(text, "Working. choice=allow-once", "allow must pick the *_once option")
        XCTAssertNil(cost, "ACP reports no dollar cost")
        XCTAssertFalse(isError)
        XCTAssertEqual(detail, "end_turn")
        XCTAssertTrue(events.contains { if case .reply("Working. choice=allow-once") = $0 { return true }; return false })
        XCTAssertEqual(adapter.state, .ready)
        XCTAssertEqual(adapter.totalTokens, 150, "per-turn usage must accumulate (100 in + 50 out)")

        // A second turn must ADD to the total, not replace it.
        adapter.send("again")
        try await waitForEvent {
            if case .permissionRequest = $0 { return self.events.filter {
                if case .permissionRequest = $0 { return true }; return false }.count == 2 }
            return false
        }
        guard case .permissionRequest(let secondID, _, _, _)? =
                events.last(where: { if case .permissionRequest = $0 { return true }; return false }) else {
            return XCTFail("no second permission request")
        }
        adapter.respondToPermission(id: secondID, allow: true)
        try await waitForEvent {
            if case .turnCompleted = $0 { return self.events.filter {
                if case .turnCompleted = $0 { return true }; return false }.count == 2 }
            return false
        }
        XCTAssertEqual(adapter.totalTokens, 300, "usage must accumulate across turns")
    }

    func testSetModelSuccessAndRejection() async throws {
        startAdapter()
        try await waitForEvent { if case .sessionReady = $0 { return true }; return false }

        adapter.setModel("mock/model-2")
        try await waitForEvent { if case .controlResult("set_model", true, _, "mock/model-2") = $0 { return true }; return false }
        XCTAssertEqual(adapter.modelName, "mock/model-2")

        adapter.setModel("bad")
        try await waitForEvent { if case .controlResult("set_model", false, _, "bad") = $0 { return true }; return false }
        XCTAssertEqual(adapter.modelName, "mock/model-2", "a rejected switch must not change the model")
    }

    // MARK: The mock agent

    private static let mockAgentScript = #"""
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        m = json.loads(line)
        method, mid = m.get("method"), m.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "MockAgent", "version": "1.0"}}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "sessionId": "mock-session",
                "models": {"currentModelId": "mock/model-1"}}})
        elif method == "session/prompt":
            sid = m["params"]["sessionId"]
            def update(u):
                send({"jsonrpc": "2.0", "method": "session/update",
                      "params": {"sessionId": sid, "update": u}})
            update({"sessionUpdate": "agent_thought_chunk",
                    "content": {"type": "text", "text": "thinking"}})
            update({"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "Working. "}})
            update({"sessionUpdate": "tool_call", "toolCallId": "t1",
                    "title": "Edit File", "kind": "edit",
                    "locations": [{"path": "/tmp/a.swift", "line": 1}]})
            send({"jsonrpc": "2.0", "id": 100, "method": "session/request_permission",
                  "params": {"sessionId": sid,
                             "toolCall": {"title": "Edit a.swift", "kind": "edit",
                                          "rawInput": {"file_path": "/tmp/a.swift"}},
                             "options": [
                                 {"optionId": "allow-always", "name": "Always", "kind": "allow_always"},
                                 {"optionId": "allow-once", "name": "Once", "kind": "allow_once"},
                                 {"optionId": "reject-once", "name": "No", "kind": "reject_once"}]}})
            chosen = "cancelled"
            for reply_line in sys.stdin:
                r = json.loads(reply_line)
                if r.get("id") == 100:
                    outcome = r.get("result", {}).get("outcome", {})
                    if outcome.get("outcome") == "selected":
                        chosen = outcome.get("optionId", "cancelled")
                    break
            update({"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "choice=" + chosen}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn",
                  "usage": {"inputTokens": 100, "outputTokens": 50}}})
        elif method == "session/set_model":
            if m["params"].get("modelId") == "bad":
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": -32602, "message": "unknown model"}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
    """#
}
