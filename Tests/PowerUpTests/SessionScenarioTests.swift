import XCTest
@testable import PowerUp

/// The session state machine, recorded as data (epic #92). Every scenario in
/// `Tests/Fixtures/session/` is played through the AppState seam with a
/// scripted harness; a broken rule fails naming the scenario and its first
/// mismatched expectation. To pin a new session rule, add a fixture there
/// rather than a bespoke test (format: `Tests/Fixtures/README.md`).
@MainActor
final class SessionScenarioTests: XCTestCase {

    // MARK: The table

    func testEverySessionScenarioHolds() async throws {
        let files = try SessionScenarioRunner.scenarioFiles()
        XCTAssertFalse(files.isEmpty, "no scenarios in \(SessionScenarioRunner.fixturesDirectory("session").path)")

        var names: [String: String] = [:]
        for file in files {
            let scenario: SessionScenario
            do {
                scenario = try SessionScenario(contentsOf: file)
            } catch {
                XCTFail("could not load \(file.lastPathComponent): \(error)")
                continue
            }
            XCTAssertEqual(scenario.name + ".json", file.lastPathComponent,
                           "[\(scenario.name)] the file must be named after its scenario")
            if let other = names[scenario.name] {
                XCTFail("[\(scenario.name)] is declared by both \(other) and \(file.lastPathComponent)")
            }
            names[scenario.name] = file.lastPathComponent

            let failures = await SessionScenarioRunner.run(scenario)
            if let first = failures.first {
                let more = failures.count > 1 ? " (+\(failures.count - 1) more mismatch(es))" : ""
                XCTFail(first + more)
            }
        }
    }

    // MARK: The directory

    func testFixturesLoadFromTheRepositoryRootRelativeToThisFile() throws {
        let directory = SessionScenarioRunner.fixturesDirectory("session")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "Fixtures")
        XCTAssertEqual(directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Tests")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Package.swift").path),
            "Tests/Fixtures must sit beside Package.swift")

        let names = try SessionScenarioRunner.scenarioFiles().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("resume-failure-retried-once-without-resume.json"), "found \(names)")
    }

    // MARK: The runner reports what broke

    func testABrokenExpectationFailsNamingTheScenario() async throws {
        var json = try Self.fixture("resume-failure-retried-once-without-resume")
        // Claim the retry resumed the stale id again, which it must not.
        json = Self.replacing(json, at: ["expect", "harnessCalls", 1, "resumeSessionID"],
                              with: .string("stale-session-id"))
        let scenario = try SessionScenario(json: json, file: "broken.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.hasPrefix("[resume-failure-retried-once-without-resume]"), message)
        XCTAssertTrue(message.contains("expect.harnessCalls[1].resumeSessionID"), message)
        XCTAssertTrue(message.contains("expected \"stale-session-id\", got null"), message)
    }

    func testAStepTaggedExpectNoChangeFailsWhenItChangesSomething() async throws {
        let scenario = try SessionScenario(json: Self.json("""
            {
              "formatVersion": 1, "name": "probe-no-change", "description": "d", "reason": "r",
              "verifiedBy": ["swift"],
              "config": { "project": true },
              "script": [
                { "call": "interruptClaude", "expectNoChange": true },
                { "call": "startSessionIfNeeded", "expectNoChange": true }
              ],
              "expect": { "status": "noController" }
            }
            """), file: "probe.json")

        let failures = await SessionScenarioRunner.run(scenario)

        // Interrupting with no session logs an error: a change. Starting one
        // records a start: also a change. Both are reported, by step.
        XCTAssertEqual(failures.count, 2, "\(failures)")
        XCTAssertTrue(failures[0].hasPrefix("[probe-no-change]"), failures[0])
        XCTAssertTrue(failures[0].contains("step 1"), failures[0])
        XCTAssertTrue(failures[0].contains("transcript"), failures[0])
        XCTAssertTrue(failures[1].contains("step 2"), failures[1])
        XCTAssertTrue(failures[1].contains("harnessCalls"), failures[1])
    }

    func testAStepThatChangesNothingPassesExpectNoChange() async throws {
        let scenario = try SessionScenario(json: Self.json("""
            {
              "formatVersion": 1, "name": "probe-ignored", "description": "d", "reason": "r",
              "verifiedBy": ["swift"],
              "config": { "project": true },
              "script": [
                { "call": "startSessionIfNeeded" },
                { "call": "startSessionIfNeeded", "expectNoChange": true,
                  "reason": "a session is already starting" }
              ],
              "expect": { "harnessCalls": [ { "type": "start", "resumeSessionID": null } ] }
            }
            """), file: "probe.json")

        let failures = await SessionScenarioRunner.run(scenario)
        XCTAssertEqual(failures, [])
    }

    // MARK: The format is strict

    func testAFixtureTypoIsALoadErrorNotASkippedCheck() throws {
        var json = try Self.fixture("resume-failure-retried-once-without-resume")
        json = Self.replacing(json, at: ["expect", "lastSesionID"], with: .null)

        XCTAssertThrowsError(try SessionScenario(json: json, file: "typo.json")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("typo.json"), message)
            XCTAssertTrue(message.contains("$.expect.lastSesionID"), message)
        }
    }

    func testRemoteModeScenariosAreRefusedUntilAFakeRemoteTargetExists() throws {
        var json = try Self.fixture("resume-failure-retried-once-without-resume")
        json = Self.replacing(json, at: ["config", "controlMode"], with: .string("remote"))

        XCTAssertThrowsError(try SessionScenario(json: json, file: "remote.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.config.controlMode"), "\(error)")
        }
    }

    // MARK: Helpers

    private static func fixture(_ name: String) throws -> ScenarioJSON {
        let url = SessionScenarioRunner.fixturesDirectory("session").appendingPathComponent(name + ".json")
        return try ScenarioJSON(parsing: Data(contentsOf: url))
    }

    private static func json(_ text: String) throws -> ScenarioJSON {
        try ScenarioJSON(parsing: Data(text.utf8))
    }

    /// `json` with the value at `path` (object keys and array indexes) set to
    /// `value`; a missing final object key is added.
    private static func replacing(_ json: ScenarioJSON, at path: [AnyHashable], with value: ScenarioJSON) -> ScenarioJSON {
        guard let head = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch (json, head) {
        case (.object(var fields), let key as String):
            fields[key] = replacing(fields[key] ?? .null, at: rest, with: value)
            return .object(fields)
        case (.array(var items), let index as Int) where items.indices.contains(index):
            items[index] = replacing(items[index], at: rest, with: value)
            return .array(items)
        default:
            return json
        }
    }
}
