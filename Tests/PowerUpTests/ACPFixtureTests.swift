import XCTest
@testable import PowerUp

/// Plays the ACP adapter's small `Tests/Fixtures/harness/acp-*.json` tables
/// (spec #99, slice 2.4) against the app: which option answers a permission
/// request, which variables leave the agent's environment, and how each
/// agent preset is launched. The Rust core plays the same files
/// (`rust/powerup-core/tests/acp.rs`).
final class ACPFixtureTests: XCTestCase {

    private static let area = "harness"

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
