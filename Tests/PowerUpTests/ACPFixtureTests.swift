import XCTest
@testable import PowerUp

/// Plays the ACP adapter's `Tests/Fixtures/harness/acp-*.json` tables (spec
/// #99, slice 2.4) against the app: the adapter's JSON-RPC rules, one agent
/// line in a ready session, which option answers a permission request, which
/// variables leave the agent's environment, and how each agent preset is
/// launched. The Rust core plays the same files
/// (`rust/powerup-core/tests/acp.rs`). Every table runs through the bridge
/// since slice 2.4's bridge ticket (#155): the app's ACP rules are the core's.
final class ACPFixtureTests: XCTestCase {

    private static let area = "harness"

    // MARK: acp-adapter.json

    /// Runs one acp step on the state machine ACPAdapter drives. Every step
    /// has exactly one key and every field is required; the configuration
    /// fields ACP ignores are filled as the Rust runner fills them.
    private func acpStep(_ machine: CoreBridge.ACPStateMachine,
                         _ step: JSONValue) throws -> [CoreBridge.ACPEffect] {
        guard case .object(let fields) = step, fields.count == 1, let key = fields.keys.first,
              let value = fields[key] else {
            throw FixtureValueError(description: "a step is not an object with one key: \(step)")
        }
        func string(_ value: JSONValue?, _ what: String) throws -> String {
            guard let text = value?.stringValue else {
                throw FixtureValueError(description: "\(what) must be a string: \(step)")
            }
            return text
        }
        func exit(_ object: JSONValue) throws -> (Int32, String) {
            guard case .integer(let code)? = object["exitCode"], let exitCode = Int32(exactly: code) else {
                throw FixtureValueError(description: "exitCode must be an Int32: \(step)")
            }
            return (exitCode, try string(object["stderrTail"], "stderrTail"))
        }
        let current = machine.generation
        let retired = current &- 1
        switch key {
        case "start":
            let agentCommand: [String]?
            switch value["agentCommand"] {
            case .null?:
                agentCommand = nil
            case .array(let parts)?:
                agentCommand = try parts.map { try string($0, "an agentCommand part") }
            default:
                throw FixtureValueError(description: "agentCommand must be a list or null: \(step)")
            }
            return machine.start(HarnessConfiguration(
                projectDir: URL(fileURLWithPath: try string(value["projectDir"], "projectDir"), isDirectory: true),
                model: "default", permissionMode: "default", effort: "default",
                resumeSessionID: nil, binaryPathOverride: nil, agentCommand: agentCommand))
        case "spawned":
            return machine.spawned(generation: current)
        case "spawnFailed":
            return machine.spawnFailed(generation: current, executable: try string(value["executable"], "executable"),
                                       description: try string(value["description"], "description"))
        case "send":
            return machine.send(try string(value, "send"))
        case "interrupt":
            return machine.interrupt()
        case "setModel":
            return machine.setModel(try string(value, "setModel"))
        case "setPermissionMode":
            return machine.setPermissionMode(try string(value, "setPermissionMode"))
        case "respondToPermission":
            guard case .bool(let allow)? = value["allow"] else {
                throw FixtureValueError(description: "allow must be a bool: \(step)")
            }
            return machine.respondToPermission(id: try string(value["id"], "id"), allow: allow)
        case "stop":
            return machine.stop()
        case "line":
            return machine.stdoutLine(generation: current, line: try FixtureLine.bytes(value))
        case "retiredLine":
            return machine.stdoutLine(generation: retired, line: try FixtureLine.bytes(value))
        case "terminated":
            let (code, tail) = try exit(value)
            return machine.terminated(generation: current, exitCode: code, stderrTail: tail)
        case "retiredTerminated":
            let (code, tail) = try exit(value)
            return machine.terminated(generation: retired, exitCode: code, stderrTail: tail)
        case "watchdog":
            return machine.startWatchdogFired(generation: current)
        case "retiredWatchdog":
            return machine.startWatchdogFired(generation: retired)
        default:
            throw FixtureValueError(description: "unknown acp step: \(step)")
        }
    }

    private struct AdapterInput: Decodable {
        let steps: [JSONValue]
    }

    private func descriptors(_ effects: [CoreBridge.ACPEffect]) throws -> JSONValue {
        .array(try effects.map { try $0.fixtureDescriptor() })
    }

    func testAcpAdapterTable() throws {
        let fileName = "acp-adapter.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: AdapterInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let machine = CoreBridge.ACPStateMachine()
            var effects: [JSONValue] = []
            for step in fixtureCase.input.steps {
                effects.append(try descriptors(try acpStep(machine, step)))
            }
            let actual = try JSONValue(encoding: JSONValue.object([
                "effects": .array(effects),
                "snapshot": machine.snapshot.fixtureFields,
            ]))
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: acp-agent-lines.json

    /// The handshake every case of the table starts from (its `function`
    /// spells it out); it must end in sessionReady(s1, m1).
    private func readyMachine() throws -> CoreBridge.ACPStateMachine {
        let machine = CoreBridge.ACPStateMachine()
        let steps: [JSONValue] = [
            .object(["start": .object(["projectDir": .string("/work/app"), "agentCommand": .array([.string("agent")])])]),
            .object(["spawned": .bool(true)]),
            .object(["line": .string(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)]),
            .object(["line": .string(#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","models":{"currentModelId":"m1"}}}"#)]),
        ]
        var last: [CoreBridge.ACPEffect] = []
        for step in steps {
            last = try acpStep(machine, step)
        }
        XCTAssertEqual(last, [.publish(.init(state: .ready, sessionID: "s1", modelName: "m1", totalTokens: 0)),
                              .emit(.sessionReady(sessionID: "s1", model: "m1"))],
                       "the acp-agent-lines.json handshake no longer reaches sessionReady")
        return machine
    }

    func testAcpAgentLinesTable() throws {
        let fileName = "acp-agent-lines.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let machine = try readyMachine()
            let effects = machine.stdoutLine(generation: machine.generation,
                                             line: try FixtureLine.bytes(fixtureCase.input))
            let actual = try JSONValue(encoding: try descriptors(effects))
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: The scrub list (the #154 acceptance criterion, Swift side)

    /// The list the core hands the app is the one ACPAdapter.agentEnvironment
    /// held before slice 2.4 (dddf9c6), exactly; the Rust twin is
    /// `environment.rs the_scrub_list_is_the_swift_list`.
    func testTheScrubListIsTheOldSwiftList() {
        XCTAssertEqual(CoreBridge.acpEnvironmentScrub,
                       CoreBridge.ACPEnvironmentScrub(names: ["CLAUDECODE", "CLAUDE_PID"], prefixes: ["CLAUDE_CODE_"]))
    }

    // MARK: acp-permission-choice.json

    private struct PermissionInput: Decodable {
        struct Option: Decodable {
            let optionId: String
            let kind: String
        }
        let options: [Option]
        let allow: Bool
    }

    func testAcpPermissionChoiceTable() throws {
        let fileName = "acp-permission-choice.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: PermissionInput.self, expected: String?.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let options = fixtureCase.input.options.map { (id: $0.optionId, kind: $0.kind) }
            let actual = ACPAdapter.permissionChoice(options: options, allow: fixtureCase.input.allow)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: acp-environment.json

    func testAcpEnvironmentTable() throws {
        let fileName = "acp-environment.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: String.self, expected: Bool.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let name = fixtureCase.input
            XCTAssertNotEqual(name, "PATH", "\(fileName) case \(fixtureCase.name): PATH is rebuilt, not scrubbed")
            let environment = ACPAdapter.agentEnvironment(from: [name: "x", "PATH": "/usr/bin"])
            let removed = environment[name] == nil
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: removed) {
                XCTFail(failure)
            }
        }
    }

    // MARK: acp-agent-launch.json

    private struct LaunchInput: Decodable {
        let agent: String
        let customCommand: String
    }

    /// The table's launch with the first install path of its program, the
    /// one `agentCommand` picks when every candidate is executable.
    private func expectedCommand(_ descriptor: JSONValue) throws -> [String]? {
        if descriptor == .null { return nil }
        guard case .array(let arguments)? = descriptor["arguments"] else {
            throw FixtureValueError(description: "a launch without arguments: \(descriptor)")
        }
        let strings = try arguments.map { argument -> String in
            guard let text = argument.stringValue else {
                throw FixtureValueError(description: "a non-string argument in \(descriptor)")
            }
            return text
        }
        let executable: String
        switch descriptor["program"] {
        case .string("opencode")?:
            executable = try XCTUnwrap(ACPAdapter.opencodeCandidates.first)
        case .string("npx")?:
            executable = try XCTUnwrap(ACPAdapter.npxCandidates.first)
        case .object(let command)? where command.keys.sorted() == ["command"]:
            guard let typed = command["command"]?.stringValue else {
                throw FixtureValueError(description: "a command program that is not a string: \(descriptor)")
            }
            executable = typed
        default:
            throw FixtureValueError(description: "an unknown program in \(descriptor)")
        }
        return [executable] + strings
    }

    func testAcpAgentLaunchTable() throws {
        let fileName = "acp-agent-launch.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: LaunchInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            var config = AppConfig.defaultConfig()
            config.acpAgent = fixtureCase.input.agent
            config.acpCustomCommand = fixtureCase.input.customCommand
            let actual = ACPAdapter.agentCommand(for: config, isExecutable: { _ in true })
            let expected = try expectedCommand(fixtureCase.expected)
            XCTAssertEqual(actual, expected,
                           "\(fileName) case \"\(fixtureCase.name)\" failed — guards: \(fixtureCase.reason)")
        }
    }

    // MARK: install paths (stay in Swift, HK-286)

    func testAgentBinariesAreProbedInOrder() {
        XCTAssertEqual(ACPAdapter.opencodeCandidates, [
            NSHomeDirectory() + "/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
        ])
        XCTAssertEqual(ACPAdapter.npxCandidates, ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"])

        var config = AppConfig.defaultConfig()
        var probed: [String] = []
        let onlySecond: (String) -> Bool = { path in
            probed.append(path)
            return path == "/opt/homebrew/bin/opencode" || path == "/usr/local/bin/npx"
        }
        config.acpAgent = "opencode"
        XCTAssertEqual(ACPAdapter.agentCommand(for: config, isExecutable: onlySecond),
                       ["/opt/homebrew/bin/opencode", "acp"])
        XCTAssertEqual(probed, Array(ACPAdapter.opencodeCandidates.prefix(2)), "the probe stops at the first hit")

        for agent in ["claudeBridge", "codexBridge"] {
            probed = []
            config.acpAgent = agent
            XCTAssertEqual(ACPAdapter.agentCommand(for: config, isExecutable: onlySecond)?.first,
                           "/usr/local/bin/npx", agent)
            XCTAssertEqual(probed, Array(ACPAdapter.npxCandidates.prefix(2)), agent)
        }

        // A missing binary resolves to no command instead of launching.
        for agent in ["opencode", "claudeBridge", "codexBridge"] {
            config.acpAgent = agent
            XCTAssertNil(ACPAdapter.agentCommand(for: config, isExecutable: { _ in false }), agent)
        }
        // A custom command is used as typed, never probed.
        config.acpAgent = "custom"
        config.acpCustomCommand = "/nowhere/agent acp"
        probed = []
        XCTAssertEqual(ACPAdapter.agentCommand(for: config, isExecutable: onlySecond), ["/nowhere/agent", "acp"])
        XCTAssertEqual(probed, [])
    }
}
