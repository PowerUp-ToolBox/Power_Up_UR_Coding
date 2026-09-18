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
}
