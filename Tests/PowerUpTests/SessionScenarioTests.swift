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

    func testDisarmingAnArmedRequestIsAnObservableChange() async throws {
        // Arming is published state (the banner retitles to "Confirm"), so a
        // step that disarms is not "no change" even though it sends nothing
        // and logs nothing.
        let scenario = try SessionScenario(json: Self.json("""
            {
              "formatVersion": 1, "name": "probe-disarm", "description": "d", "reason": "r",
              "verifiedBy": ["swift"],
              "config": { "project": true },
              "script": [
                { "call": "sendUserText", "text": "go" },
                { "harnessEvent": { "type": "permissionRequest", "id": "p", "name": "Bash",
                                    "kind": "execute", "detail": "rm -rf build" } },
                { "intent": "approve" },
                { "intent": "stopSpeaking", "expectNoChange": true }
              ],
              "expect": { "pendingPermission": true, "pendingPermissionArmed": false }
            }
            """), file: "probe.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("step 4"), message)
        XCTAssertTrue(message.contains("pendingPermissionArmed (true → false)"), message)
    }

    func testAStepCheckpointFailureNamesTheStep() async throws {
        var json = try Self.fixture("effort-change-mid-turn-restarts-with-resume-after-the-turn")
        // Claim the mid-turn press restarted at once, which it must not.
        json = Self.replacing(json, at: ["script", 3, "expect", "harnessCalls"], with: .array([
            .object(["type": .string("start")]),
            .object(["type": .string("send")]),
            .object(["type": .string("start"), "resumeSessionID": .string("session-1")]),
        ]))
        let scenario = try SessionScenario(json: json, file: "broken.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.hasPrefix("[effort-change-mid-turn-restarts-with-resume-after-the-turn]"), message)
        XCTAssertTrue(message.contains("step 4 expect.harnessCalls[2]"), message)
        XCTAssertTrue(message.contains("got nothing"), message)
    }

    func testSettleFalseRunsTheNextStepBeforeDeferredWork() async throws {
        // Without `"settle": false` the deferred effort restart runs as soon as
        // the first turn completes, so the second prompt lands on the new
        // process instead of postponing the restart: the re-deferral scenario
        // only exercises its rule because of that flag.
        var json = try Self.fixture("effort-restart-re-deferred-by-a-new-turn")
        json = Self.removing(json, at: ["script", 4], key: "settle")
        let scenario = try SessionScenario(json: json, file: "settled.json")

        let failures = await SessionScenarioRunner.run(scenario)

        let first = try XCTUnwrap(failures.first, "the restart should have run before the second prompt")
        XCTAssertTrue(first.contains("step 6 expect.harnessCalls[2]"), first)
        XCTAssertTrue(first.contains("\"resumeSessionID\": \"session-1\""), first)
    }

    func testTheLastStepCannotSkipSettling() throws {
        var json = try Self.fixture("effort-change-between-turns-restarts-now-with-resume")
        json = Self.replacing(json, at: ["script", 2, "settle"], with: .bool(false))

        XCTAssertThrowsError(try SessionScenario(json: json, file: "last.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.script[2].settle"), "\(error)")
        }
    }

    func testAChangedLiveModelIsAnObservableChange() async throws {
        let scenario = try SessionScenario(json: Self.json("""
            {
              "formatVersion": 1, "name": "probe-live-model", "description": "d", "reason": "r",
              "verifiedBy": ["swift"],
              "config": { "project": true, "model": "sonnet" },
              "script": [
                { "call": "startSessionIfNeeded" },
                { "harnessEvent": { "type": "sessionReady", "sessionID": "s", "model": "claude-sonnet-4-5" } },
                { "harnessEvent": { "type": "sessionReady", "sessionID": "s", "model": "claude-opus-4-1" },
                  "expectNoChange": true }
              ],
              "expect": { "modelChip": "sonnet" }
            }
            """), file: "probe.json")

        let failures = await SessionScenarioRunner.run(scenario)

        // A repeated init logs nothing and the explicit alias keeps the chip,
        // but the live model moved.
        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("step 3"), message)
        XCTAssertTrue(message.contains("liveModel (claude-sonnet-4-5 → claude-opus-4-1)"), message)
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

    func testAdvanceClockMustBeANonNegativeNumberOfSeconds() throws {
        var json = try Self.fixture("remote-turn-expires-after-fifteen-silent-minutes")
        json = Self.replacing(json, at: ["script", 1, "advanceClock"], with: .number(-1))

        XCTAssertThrowsError(try SessionScenario(json: json, file: "clock.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.script[1].advanceClock"), "\(error)")
        }
    }

    func testAnUnknownHookEventIsALoadError() throws {
        var json = try Self.fixture("remote-turn-expires-after-fifteen-silent-minutes")
        json = Self.replacing(json, at: ["script", 0, "hookEvent", "type"], with: .string("preToolUse"))

        XCTAssertThrowsError(try SessionScenario(json: json, file: "hook.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.script[0].hookEvent.type"), "\(error)")
        }
    }

    // MARK: Remote mode (#118)

    func testRemoteModeTypesIntoTheRecordingInjectorNeverARealTerminal() async throws {
        let scenario = try SessionScenario(json: Self.json("""
            {
              "formatVersion": 1, "name": "probe-remote", "description": "d", "reason": "r",
              "verifiedBy": ["swift"],
              "config": { "controlMode": "remote" },
              "script": [
                { "intent": "sendPrompt", "text": "Hello there" },
                { "intent": "reject" }
              ],
              "expect": {
                "injectorCalls": [
                  { "type": "text", "text": "Hello there", "submit": true },
                  { "type": "key", "key": "enter" }
                ]
              }
            }
            """), file: "probe.json")

        let failures = await SessionScenarioRunner.run(scenario)

        // Reject is Escape in remote mode, not Enter: the mismatch shows the
        // recording is real and compared element by element.
        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.hasPrefix("[probe-remote]"), message)
        XCTAssertTrue(message.contains("expect.injectorCalls[1].key: expected \"enter\", got \"escape\""), message)
    }

    func testAnExpiringRemoteTurnIsAnObservableChange() async throws {
        var json = try Self.fixture("remote-turn-expires-after-fifteen-silent-minutes")
        json = Self.replacing(json, at: ["script", 2, "expectNoChange"], with: .bool(true))
        let scenario = try SessionScenario(json: json, file: "expiry.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("step 3"), message)
        XCTAssertTrue(message.contains("status (thinking → idle)"), message)
    }

    func testWithoutAdvancingTheClockARemoteTurnNeverExpires() async throws {
        // The expiry is driven by the scripted clock alone: drop the step that
        // crosses fifteen minutes and the turn is still working at the end.
        var json = try Self.fixture("remote-turn-expires-after-fifteen-silent-minutes")
        json = Self.replacing(json, at: ["script", 2, "advanceClock"], with: .number(0))
        let scenario = try SessionScenario(json: json, file: "frozen.json")

        let failures = await SessionScenarioRunner.run(scenario)

        let first = try XCTUnwrap(failures.first, "the turn should still be working")
        XCTAssertTrue(first.contains("expect.status: expected \"idle\", got \"thinking\""), first)
    }

    // MARK: Harness kinds and lifecycle (#119)

    func testHarnessCallsNameTheAdapterThatReceivedThem() async throws {
        var json = try Self.fixture("harness-switch-stops-the-old-adapter-before-the-new-one-starts")
        // Claim the built-in adapter started after the switch, not the agent.
        json = Self.replacing(json, at: ["expect", "harnessCalls", 2, "adapter"], with: .string("claude"))
        let scenario = try SessionScenario(json: json, file: "adapter.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("expect.harnessCalls[2].adapter: expected \"claude\", got \"acp\""), message)
    }

    func testAHarnessEventComesFromTheNamedAdapter() async throws {
        // Without "adapter", the late reply comes from the active harness
        // (the agent), so it is a real reply and changes the transcript.
        var json = try Self.fixture("harness-switch-ignores-the-retired-adapters-late-events")
        json = Self.removing(json, at: ["script", 7], key: "adapter")
        let scenario = try SessionScenario(json: json, file: "late.json")

        let failures = await SessionScenarioRunner.run(scenario)

        let first = try XCTUnwrap(failures.first, "the active adapter's reply must be heard")
        XCTAssertTrue(first.contains("step 8"), first)
        XCTAssertTrue(first.contains("changed transcript"), first)
    }

    func testAClearedLiveSessionIDIsAnObservableChange() async throws {
        var json = try Self.fixture("hooks-from-our-ended-session-are-heard-in-remote-mode")
        json = Self.replacing(json, at: ["script", 4, "expectNoChange"], with: .bool(true))
        let scenario = try SessionScenario(json: json, file: "ended.json")

        let failures = await SessionScenarioRunner.run(scenario)

        XCTAssertEqual(failures.count, 1, "\(failures)")
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.contains("step 5"), message)
        XCTAssertTrue(message.contains("liveSessionID (session-1 → null)"), message)
    }

    func testTheACPHarnessMustUseTheCustomAgent() throws {
        // Any other agent's command is looked up on this machine's disk.
        var configured = try Self.fixture("no-ultracode-prefix-for-an-acp-harness")
        configured = Self.replacing(configured, at: ["config", "acpAgent"], with: .string("opencode"))
        XCTAssertThrowsError(try SessionScenario(json: configured, file: "agent.json")) { error in
            XCTAssertTrue(String(describing: error).contains("agent.json $.config:"), "\(error)")
        }

        var switched = try Self.fixture("harness-switch-stops-the-old-adapter-before-the-new-one-starts")
        switched = Self.removing(switched, at: ["script", 2, "settings"], key: "acpAgent")
        XCTAssertThrowsError(try SessionScenario(json: switched, file: "switch.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.script[2].settings"), "\(error)")
        }
    }

    func testStepFieldsBelongToTheirStepKinds() throws {
        var adapter = try Self.fixture("session-id-clears-on-termination")
        adapter = Self.replacing(adapter, at: ["script", 0, "adapter"], with: .string("claude"))
        XCTAssertThrowsError(try SessionScenario(json: adapter, file: "adapter.json")) { error in
            XCTAssertTrue(String(describing: error).contains("$.script[0].adapter"), "\(error)")
        }

        var project = try Self.fixture("project-switch-in-remote-mode-starts-no-session")
        project = Self.removing(project, at: ["script", 0], key: "project")
        XCTAssertThrowsError(try SessionScenario(json: project, file: "project.json")) { error in
            XCTAssertTrue(String(describing: error).contains("switchProject needs \"project\""), "\(error)")
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

    /// `json` with `key` removed from the object at `path`.
    private static func removing(_ json: ScenarioJSON, at path: [AnyHashable], key: String) -> ScenarioJSON {
        guard let head = path.first else {
            guard case .object(var fields) = json else { return json }
            fields[key] = nil
            return .object(fields)
        }
        let rest = Array(path.dropFirst())
        switch (json, head) {
        case (.object(var fields), let name as String):
            if let inner = fields[name] { fields[name] = removing(inner, at: rest, key: key) }
            return .object(fields)
        case (.array(var items), let index as Int) where items.indices.contains(index):
            items[index] = removing(items[index], at: rest, key: key)
            return .array(items)
        default:
            return json
        }
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
