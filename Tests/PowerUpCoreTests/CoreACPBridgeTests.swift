import XCTest
import PowerUpCore

/// The ACP harness half of the bridge (slice 2.4): the `CoreAcpAdapter`
/// object keeps a launch's state between calls and answers raw agent lines,
/// and the permission choice, the agent presets and the scrub list answer
/// through the generated functions.
final class CoreACPBridgeTests: XCTestCase {

    private let configuration = CoreHarnessConfiguration(projectDir: "/work/app", model: "default",
                                                         permissionMode: "default", effort: "default",
                                                         resumeSessionId: nil, binaryPathOverride: nil,
                                                         agentCommand: ["agent", "acp"])

    private func object(_ line: Data) throws -> [String: Any] {
        XCTAssertEqual(line.last, 0x0A, "a JSON-RPC line ends with its newline")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    func testAStartPublishesStartingAndSpawnsTheAgent() throws {
        let adapter = try CoreAcpAdapter()
        XCTAssertEqual(try adapter.generation(), 0)
        XCTAssertEqual(try adapter.start(configuration: configuration), [
            .publish(snapshot: CoreAcpSnapshot(state: .starting, sessionId: nil, modelName: nil, totalTokens: 0)),
            .spawn(generation: 1, executable: "agent", arguments: ["acp"], projectDir: "/work/app")
        ])
        XCTAssertEqual(try adapter.generation(), 1)
    }

    /// The handshake through the object: initialize on spawn, session/new
    /// with the project folder, then sessionReady; the ids keep counting.
    func testTheAdapterKeepsItsStateAcrossCalls() throws {
        let adapter = try CoreAcpAdapter()
        _ = try adapter.start(configuration: configuration)
        let spawned = try adapter.spawned(generation: 1)
        guard spawned.count == 2, case .writeStdin(let initialize) = spawned[0],
              case .armStartWatchdog(1, 30) = spawned[1] else {
            return XCTFail("no initialize and watchdog: \(spawned)")
        }
        XCTAssertEqual(try object(initialize)["method"] as? String, "initialize")
        XCTAssertEqual(try object(initialize)["id"] as? Int, 1)

        // A retired generation's line is dropped.
        let ack = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        XCTAssertEqual(try adapter.stdoutLine(generation: 0, line: ack), [])
        guard case .writeStdin(let sessionNew)? = try adapter.stdoutLine(generation: 1, line: ack).first else {
            return XCTFail("no session/new")
        }
        let request = try object(sessionNew)
        XCTAssertEqual(request["method"] as? String, "session/new")
        XCTAssertEqual((request["params"] as? [String: Any])?["cwd"] as? String, "/work/app")

        let created = Data(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","models":{"currentModelId":"m1"}}}"#.utf8)
        XCTAssertEqual(try adapter.stdoutLine(generation: 1, line: created), [
            .publish(snapshot: CoreAcpSnapshot(state: .ready, sessionId: "s1", modelName: "m1", totalTokens: 0)),
            .emit(event: .sessionReady(sessionId: "s1", model: "m1"))
        ])
        XCTAssertEqual(try adapter.startWatchdogFired(generation: 1), [], "a ready launch is never timed out")
        XCTAssertEqual(try adapter.stop(), [
            .closeStdin,
            .publish(snapshot: CoreAcpSnapshot(state: .stopped, sessionId: nil, modelName: "m1", totalTokens: 0)),
            .terminateAfterGrace(seconds: 2)
        ])
        XCTAssertEqual(try adapter.terminated(generation: 1, exitCode: 0, stderrTail: ""), [], "an expected exit is silent")
    }

    func testThePermissionChoiceAnswers() throws {
        let options = [CoreAcpPermissionOption(optionId: "aa", kind: "allow_always"),
                       CoreAcpPermissionOption(optionId: "ao", kind: "allow_once"),
                       CoreAcpPermissionOption(optionId: "ro", kind: "reject_once")]
        XCTAssertEqual(try acpPermissionChoice(options: options, allow: true), "ao")
        XCTAssertEqual(try acpPermissionChoice(options: options, allow: false), "ro")
        XCTAssertNil(try acpPermissionChoice(options: [], allow: true))
    }

    func testThePresetsAndTheScrubListAnswer() throws {
        XCTAssertEqual(try acpAgentLaunch(agent: "opencode", customCommand: ""),
                       CoreAcpAgentLaunch(program: .opencode, arguments: ["acp"]))
        XCTAssertEqual(try acpAgentLaunch(agent: "claudeBridge", customCommand: ""),
                       CoreAcpAgentLaunch(program: .npx, arguments: ["-y", "@agentclientprotocol/claude-agent-acp"]))
        XCTAssertEqual(try acpAgentLaunch(agent: "custom", customCommand: " /x/agent  acp "),
                       CoreAcpAgentLaunch(program: .command(executable: "/x/agent"), arguments: ["acp"]))
        XCTAssertNil(try acpAgentLaunch(agent: "warp-drive", customCommand: "x"))
        XCTAssertEqual(try acpEnvironmentScrub(),
                       CoreAcpEnvironmentScrub(names: ["CLAUDECODE", "CLAUDE_PID"], prefixes: ["CLAUDE_CODE_"]))
    }
}
