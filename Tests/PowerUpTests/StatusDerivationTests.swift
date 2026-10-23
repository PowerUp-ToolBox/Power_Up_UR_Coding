import XCTest
@testable import PowerUp

/// Pins the status precedence of DESIGN v2.6: live activity (listening,
/// speaking, thinking) always outranks the missing controller, because the
/// controller is optional — voice capture can run from the mic button or the
/// keyboard. "No Controller" is only the resting state.
final class StatusDerivationTests: XCTestCase {

    private func status(connected: Bool = true,
                        ptt: Bool = false,
                        speaking: Bool = false,
                        working: Bool = false) -> AppStatus {
        AppState.derivedStatus(controllerConnected: connected,
                               isPTTActive: ptt,
                               isSpeaking: speaking,
                               isWorking: working)
    }

    // MARK: Resting states

    func testIdleWhenConnectedAndNothingHappening() {
        XCTAssertEqual(status(connected: true), .idle)
    }

    func testNoControllerOnlyWhenDisconnectedAndNothingHappening() {
        XCTAssertEqual(status(connected: false), .noController)
    }

    // MARK: Activity wins with no controller — the keyboard/mic path

    func testListeningWinsOverNoController() {
        XCTAssertEqual(status(connected: false, ptt: true), .listening)
    }

    func testSpeakingWinsOverNoController() {
        XCTAssertEqual(status(connected: false, speaking: true), .speaking)
    }

    func testThinkingWinsOverNoController() {
        XCTAssertEqual(status(connected: false, working: true), .thinking)
    }

    // MARK: Precedence between activities (unchanged from v1)

    func testListeningBeatsSpeakingAndThinking() {
        XCTAssertEqual(status(ptt: true, speaking: true, working: true), .listening)
        XCTAssertEqual(status(connected: false, ptt: true, speaking: true, working: true), .listening)
    }

    func testSpeakingBeatsThinking() {
        XCTAssertEqual(status(speaking: true, working: true), .speaking)
    }

    // MARK: The v2.6 precedence table (Tests/Fixtures/status/derivation.json)

    private static let derivationFile = "derivation.json"
    private static let workingFile = "working.json"
    private static let remoteTurnsFile = "remote-turns.json"

    struct DerivationInput: Decodable, Hashable {
        let controllerConnected: Bool
        let isPTTActive: Bool
        let isSpeaking: Bool
        let isWorking: Bool
    }

    /// The fixture's status names. An exhaustive switch, so a new `AppStatus`
    /// case cannot be added without deciding its fixture name here.
    static func fixtureName(_ status: AppStatus) -> String {
        switch status {
        case .noController: return "noController"
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        }
    }

    func testPrecedenceTableMatchesFixture() throws {
        let file = try TextSafetyFixtures.load(Self.derivationFile, area: "status",
                                               input: DerivationInput.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, Self.derivationFile)
        for fixtureCase in file.cases {
            let input = fixtureCase.input
            let actual = Self.fixtureName(AppState.derivedStatus(controllerConnected: input.controllerConnected,
                                                                 isPTTActive: input.isPTTActive,
                                                                 isSpeaking: input.isSpeaking,
                                                                 isWorking: input.isWorking))
            if let failure = TextSafetyFixtures.mismatch(in: Self.derivationFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// The table is the whole truth table: all 16 input combinations, each
    /// once. Deleting or duplicating a row is caught here, so every branch of
    /// the function (and every precedence pair) stays pinned.
    func testPrecedenceTableCoversEveryInputCombinationOnce() throws {
        let file = try TextSafetyFixtures.load(Self.derivationFile, area: "status",
                                               input: DerivationInput.self, expected: String.self)
        var expected = Set<DerivationInput>()
        for connected in [false, true] {
            for ptt in [false, true] {
                for speaking in [false, true] {
                    for working in [false, true] {
                        expected.insert(DerivationInput(controllerConnected: connected, isPTTActive: ptt,
                                                        isSpeaking: speaking, isWorking: working))
                    }
                }
            }
        }
        let inputs = file.cases.map(\.input)
        XCTAssertEqual(inputs.count, 16, "\(Self.derivationFile): expected the full 16-row table")
        XCTAssertEqual(Set(inputs), expected, "\(Self.derivationFile): missing or duplicated input rows")
    }

    // MARK: Every precedence pair, independent of the fixture

    /// listening > speaking > thinking > (noController | idle), checked pair
    /// by pair with only the two contenders switched on, pad connected or not.
    func testEveryPrecedencePairResolvesToTheHigherState() {
        typealias Signal = (status: AppStatus, ptt: Bool, speaking: Bool, working: Bool)
        let ranked: [Signal] = [
            (.listening, true, false, false),
            (.speaking, false, true, false),
            (.thinking, false, false, true),
        ]
        for connected in [false, true] {
            let resting: AppStatus = connected ? .idle : .noController
            for (index, higher) in ranked.enumerated() {
                // Each activity against the resting state.
                XCTAssertEqual(status(connected: connected, ptt: higher.ptt,
                                      speaking: higher.speaking, working: higher.working),
                               higher.status,
                               "\(higher.status) must outrank \(resting)")
                // Each activity against every lower activity.
                for lower in ranked[(index + 1)...] {
                    XCTAssertEqual(status(connected: connected,
                                          ptt: higher.ptt || lower.ptt,
                                          speaking: higher.speaking || lower.speaking,
                                          working: higher.working || lower.working),
                                   higher.status,
                                   "\(higher.status) must outrank \(lower.status) (connected: \(connected))")
                }
            }
        }
        // The resting pair is decided by the pad alone.
        XCTAssertEqual(status(connected: true), .idle)
        XCTAssertEqual(status(connected: false), .noController)
    }

    // MARK: Remote-mode variants of isWorking (Tests/Fixtures/status/working.json)

    struct WorkingInput: Decodable, Hashable {
        let harnessState: String
        let isRemoteMode: Bool
        let remoteTurnActive: Bool
    }

    /// Every harness state, named as in the fixture. The switch is exhaustive,
    /// so a new state forces a decision (and new fixture rows).
    static func fixtureName(_ state: HarnessState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .ready: return "ready"
        case .working: return "working"
        }
    }

    static let allHarnessStates: [HarnessState] = [.stopped, .starting, .ready, .working]

    static func harnessState(named name: String) -> HarnessState? {
        allHarnessStates.first { fixtureName($0) == name }
    }

    func testWorkingFoldMatchesFixture() throws {
        let file = try TextSafetyFixtures.load(Self.workingFile, area: "status",
                                               input: WorkingInput.self, expected: Bool.self)
        TextSafetyFixtures.assertWellFormed(file, Self.workingFile)
        for fixtureCase in file.cases {
            guard let state = Self.harnessState(named: fixtureCase.input.harnessState) else {
                XCTFail("\(Self.workingFile) case \"\(fixtureCase.name)\": unknown harness state "
                        + "\"\(fixtureCase.input.harnessState)\"")
                continue
            }
            let actual = AppState.derivedIsWorking(harnessState: state,
                                                   isRemoteMode: fixtureCase.input.isRemoteMode,
                                                   remoteTurnActive: fixtureCase.input.remoteTurnActive)
            if let failure = TextSafetyFixtures.mismatch(in: Self.workingFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    func testWorkingFoldTableCoversEveryCombinationOnce() throws {
        let file = try TextSafetyFixtures.load(Self.workingFile, area: "status",
                                               input: WorkingInput.self, expected: Bool.self)
        var expected = Set<WorkingInput>()
        for state in Self.allHarnessStates {
            for remote in [false, true] {
                for turn in [false, true] {
                    expected.insert(WorkingInput(harnessState: Self.fixtureName(state),
                                                 isRemoteMode: remote, remoteTurnActive: turn))
                }
            }
        }
        let inputs = file.cases.map(\.input)
        XCTAssertEqual(inputs.count, expected.count, "\(Self.workingFile): expected one row per combination")
        XCTAssertEqual(Set(inputs), expected, "\(Self.workingFile): missing or duplicated input rows")
    }

    // MARK: Remote turn activity (Tests/Fixtures/status/remote-turns.json)

    struct RemoteTurnsInput: Decodable {
        let turnAgesSeconds: [String: Double]
        let focus: String?
        let expirySeconds: Double
    }

    struct RemoteTurnsExpected: Decodable, Equatable {
        let kept: [String]
        let active: Bool
    }

    func testRemoteTurnActivityMatchesFixture() throws {
        let file = try TextSafetyFixtures.load(Self.remoteTurnsFile, area: "status",
                                               input: RemoteTurnsInput.self,
                                               expected: RemoteTurnsExpected.self)
        TextSafetyFixtures.assertWellFormed(file, Self.remoteTurnsFile)
        // A fixed clock: ages become absolute timestamps against it.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for fixtureCase in file.cases {
            let input = fixtureCase.input
            let turns = input.turnAgesSeconds.mapValues { now.addingTimeInterval(-$0) }
            let live = AppState.liveRemoteTurns(turns, now: now, expiry: input.expirySeconds)
            let actual = RemoteTurnsExpected(kept: live.keys.sorted(),
                                             active: AppState.remoteTurnIsActive(live, focus: input.focus))
            if let failure = TextSafetyFixtures.mismatch(in: Self.remoteTurnsFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// The fixture rows use 900 s; this pins that the app really uses it.
    @MainActor
    func testRemoteTurnExpiryIsFifteenMinutes() {
        XCTAssertEqual(AppState.remoteTurnExpiry, 15 * 60)
    }

    // MARK: Remote mode end to end through the pure pieces

    private func remoteStatus(connected: Bool = true,
                              ptt: Bool = false,
                              speaking: Bool = false,
                              harness: HarnessState = .stopped,
                              remoteMode: Bool,
                              remoteTurn: Bool) -> AppStatus {
        status(connected: connected, ptt: ptt, speaking: speaking,
               working: AppState.derivedIsWorking(harnessState: harness,
                                                  isRemoteMode: remoteMode,
                                                  remoteTurnActive: remoteTurn))
    }

    func testRemoteTurnShowsThinkingEvenWithNoController() {
        XCTAssertEqual(remoteStatus(connected: true, remoteMode: true, remoteTurn: true), .thinking)
        XCTAssertEqual(remoteStatus(connected: false, remoteMode: true, remoteTurn: true), .thinking)
    }

    func testRemoteModeRestsWhenNoTurnIsActive() {
        XCTAssertEqual(remoteStatus(connected: true, remoteMode: true, remoteTurn: false), .idle)
        XCTAssertEqual(remoteStatus(connected: false, remoteMode: true, remoteTurn: false), .noController)
    }

    func testSpeakingAndListeningOutrankARemoteTurn() {
        XCTAssertEqual(remoteStatus(speaking: true, remoteMode: true, remoteTurn: true), .speaking)
        XCTAssertEqual(remoteStatus(connected: false, ptt: true, speaking: true,
                                    remoteMode: true, remoteTurn: true), .listening)
    }

    func testStaleRemoteTurnIsIgnoredInBuiltInMode() {
        XCTAssertEqual(remoteStatus(connected: true, harness: .ready, remoteMode: false, remoteTurn: true), .idle)
        XCTAssertEqual(remoteStatus(connected: false, remoteMode: false, remoteTurn: true), .noController)
    }
}
