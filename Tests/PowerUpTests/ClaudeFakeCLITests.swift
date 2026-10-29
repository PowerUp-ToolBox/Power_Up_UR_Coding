import XCTest
@testable import PowerUp

/// End to end through the real pipe (spec #98, slice 2.3, #152): AppState and
/// a real `ClaudeService` drive a fake `claude` — a `/bin/sh` script this
/// test writes — so the bytes cross a real process boundary, are split and
/// parsed by the core, run through the core's adapter and session rules, and
/// come back as transcript entries, config writes and stdin lines.
///
/// The script never reaches the network or a real claude: `config.claudePath`
/// points at it, and `ClaudeService.resolveClaudeBinary` takes a runnable
/// override before any login-shell lookup (the test refuses to start when the
/// script is not runnable). It speaks the verified wire shapes of DESIGN.md
/// v1.1 A: it refuses to run without `--verbose`, exits 1 on the flat
/// control-request shape as the real CLI does, prints the init line, answers
/// a user turn with a streamed delta, a thinking-only message, the same
/// assistant message twice, a rate-limit event and a result, and acknowledges
/// `set_model`. It logs its argv per launch and every stdin line it reads.
@MainActor
final class ClaudeFakeCLITests: XCTestCase {

    private var env: AppStateTestEnvironment!
    private var service: ClaudeService!
    private var logDirectory: URL!
    private var scriptURL: URL!

    private static let reply = "Hello from the fake CLI."

    /// `@LOG@` is replaced with the log directory. Each launch bumps a
    /// counter, logs its argv one argument per line to `argv-<n>.txt`, and
    /// records its exit in `exits`, so tear-down can wait for every launch
    /// to be gone before deleting the directory.
    private static let script = #"""
    #!/bin/sh
    LOG='@LOG@'
    n=$(cat "$LOG/count" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$LOG/count"
    trap 'echo "$n" >> "$LOG/exits"' EXIT
    : > "$LOG/argv-$n.txt"
    for arg in "$@"; do printf '%s\n' "$arg" >> "$LOG/argv-$n.txt"; done

    verbose=0
    session=fake-session-1
    previous=
    for arg in "$@"; do
      [ "$arg" = "--verbose" ] && verbose=1
      [ "$previous" = "--resume" ] && session=$arg
      previous=$arg
    done
    if [ "$verbose" -ne 1 ]; then
      echo "Error: When using --print, --output-format=stream-json requires --verbose" >&2
      exit 1
    fi

    printf '{"type":"system","subtype":"init","session_id":"%s","model":"claude-fake-1","cwd":"%s"}\n' "$session" "$PWD"
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$LOG/stdin.txt"
      case "$line" in
        *'"type":"control_request","subtype"'*)
          echo "Error: Missing request on control_request" >&2
          exit 1
          ;;
        *'"type":"user"'*)
          printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from"}}}'
          printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}'
          printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the fake CLI."}]}}'
          printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the fake CLI."}]}}'
          printf '%s\n' '{"type":"rate_limit_event","info":{}}'
          printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Hello from the fake CLI.","total_cost_usd":0.5}'
          ;;
        *'"subtype":"set_model"'*)
          id=$(printf '%s\n' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
          printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$id"
          printf '%s\n' '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model</local-command-stdout>"}}'
          ;;
      esac
    done
    """#

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-fake-cli-\(UUID().uuidString)", isDirectory: true)
        logDirectory = root.appendingPathComponent("log", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        scriptURL = root.appendingPathComponent("fake-claude")
        try Self.script.replacingOccurrences(of: "@LOG@", with: logDirectory.path)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        // Never let the lookup fall through to a real claude.
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("the fake claude script could not be made executable")
        }

        var config = AppConfig.defaultConfig()
        config.projectDir = projectDirectory.path
        config.claudePath = scriptURL.path
        config.ttsEnabled = false
        config.model = "default"
        config.effort = "default"
        config.lastSessionID = nil
        config.sessionIDsByProject = [:]
        env = try AppStateTestEnvironment(config: config)
        service = ClaudeService()
    }

    override func tearDown() async throws {
        service?.stop()
        // Let every launch exit before its log directory goes.
        await waitUntil(timeout: 5) { self.exits >= self.launches }
        service = nil
        env?.tearDown()
        if let scriptURL { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    }

    // MARK: Helpers

    private func file(_ name: String) -> String {
        (try? String(contentsOf: logDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private var launches: Int { Int(file("count").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    private var exits: Int { file("exits").split(separator: "\n").count }

    private func argv(_ launch: Int) -> [String] {
        file("argv-\(launch).txt").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// Every line the fake CLI read on stdin, as JSON.
    private func stdinLines() throws -> [JSONValue] {
        try file("stdin.txt").split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// Polls with 100 ms sleeps, because this is real I/O; bounded, so a
    /// broken pipe fails instead of hanging.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        var elapsed: TimeInterval = 0
        while !condition(), elapsed < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 0.1
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                         in app: AppState) async throws {
        await waitUntil(timeout: timeout, condition)
        guard condition() else {
            throw Timeout(description: "timed out waiting for \(what); transcript: \(app.transcript.map(\.text)), "
                          + "stdin: \(file("stdin.txt"))")
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private func pair(_ arguments: [String], _ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Tests

    func testATurnRunsThroughTheRealPipeIntoTheCore() async throws {
        let app = env.makeAppState(claude: service, harness: service)

        app.sendUserText("Say hello.")
        try await waitFor("the turn to complete", { app.lastAssistantReply != nil && self.service.state == .ready },
                          in: app)

        XCTAssertEqual(launches, 1)
        XCTAssertEqual(app.transcript.filter { $0.kind == .user }.map(\.text), ["Say hello."])
        XCTAssertTrue(app.transcript.contains { $0.kind == .system && $0.text == "Session started (claude-fake-1)" },
                      "\(app.transcript.map(\.text))")
        // The CLI repeats the message once per content block; the core keeps one.
        XCTAssertEqual(app.transcript.filter { $0.kind == .assistant }.map(\.text), [Self.reply])
        XCTAssertEqual(app.transcript.filter { $0.kind == .error }.map(\.text), [])
        XCTAssertEqual(app.lastAssistantReply, Self.reply)
        XCTAssertEqual(app.liveAssistantText, "")
        XCTAssertEqual(service.totalCostUSD, 0.5)
        XCTAssertEqual(service.sessionID, "fake-session-1")
        XCTAssertEqual(app.configStore.config.lastSessionID, "fake-session-1")
        XCTAssertEqual(app.configStore.config.sessionIDsByProject[app.configStore.config.projectDir ?? ""],
                       "fake-session-1")

        // The turn was queued while the binary resolved, then written as the
        // user envelope.
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Say hello."}]},"parent_tool_use_id":null}
            """#.utf8))
        XCTAssertEqual(try stdinLines(), [expected])
        let arguments = argv(1)
        XCTAssertTrue(arguments.contains("--verbose"), "\(arguments)")
        XCTAssertNil(pair(arguments, "--resume"), "a fresh folder starts a fresh session: \(arguments)")
    }

    func testModelChangeAndEffortRestartReachTheFakeCLI() async throws {
        let app = env.makeAppState(claude: service, harness: service)

        app.startSessionIfNeeded()
        try await waitFor("the session to start", { self.service.state == .ready }, in: app)

        // A live set_model, in the nested envelope, acknowledged by the CLI.
        app.handle(.cycleModel)
        let model = app.configStore.config.model
        XCTAssertNotEqual(model, "default")
        try await waitFor("the model ack", { app.harnessReportedModel == model }, in: app)
        let lines = try stdinLines()
        let setModel = lines.filter { $0["type"] == .string("control_request") }
        XCTAssertEqual(setModel.count, 1, "\(lines)")
        for line in setModel {
            XCTAssertNil(line["subtype"], "the flat shape kills the CLI: \(line)")
            XCTAssertNotNil(line["request_id"]?.stringValue, "\(line)")
            XCTAssertEqual(line["request"], .object(["subtype": .string("set_model"), "model": .string(model)]))
        }
        XCTAssertEqual(app.modelChipLabel, model)

        // There is no live effort switch: the CLI restarts with the new
        // effort, resuming the session so its context carries on.
        app.handle(.cycleEffort)
        let effort = app.configStore.config.effort
        XCTAssertNotEqual(effort, "default")
        try await waitFor("the restart", {
            self.launches == 2 && self.service.state == .ready
                && app.transcript.filter { $0.text == "Session started (claude-fake-1)" }.count == 2
        }, in: app)

        let arguments = argv(2)
        XCTAssertEqual(pair(arguments, "--effort"), effort, "\(arguments)")
        XCTAssertEqual(pair(arguments, "--resume"), "fake-session-1", "\(arguments)")
        XCTAssertEqual(pair(arguments, "--model"), model, "\(arguments)")
        XCTAssertTrue(arguments.contains("--verbose"), "\(arguments)")
        XCTAssertTrue(arguments.contains("--include-partial-messages"), "\(arguments)")
        XCTAssertEqual(service.sessionID, "fake-session-1")
        XCTAssertEqual(app.configStore.config.lastSessionID, "fake-session-1")
        // The retired process's exit is not the new session ending.
        await waitUntil(timeout: 5) { self.exits >= 1 }
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(app.transcript.filter { $0.kind == .error }.map(\.text), [])
        XCTAssertFalse(app.transcript.contains { $0.text.hasPrefix("Couldn't resume") || $0.text.hasPrefix("Claude session ended") },
                       "\(app.transcript.map(\.text))")
    }
}
