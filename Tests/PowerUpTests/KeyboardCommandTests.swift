import XCTest
import AppKit
@testable import PowerUp

/// Pins the keyboard chord → command mapping behind the local NSEvent
/// monitor (DESIGN v2.6). The monitor — not SwiftUI key equivalents —
/// delivers the app's shortcuts, so this table is the behavior.
final class KeyboardCommandTests: XCTestCase {

    private func command(_ key: String,
                         _ modifiers: NSEvent.ModifierFlags) -> AppState.KeyboardCommand? {
        AppState.keyboardCommand(forKey: key, modifiers: modifiers)
    }

    func testDictateToggleIsCommandD() {
        XCTAssertEqual(command("d", [.command]), .dictateToggle)
    }

    func testTalkToggleIsShiftCommandD() {
        XCTAssertEqual(command("d", [.command, .shift]), .talkToggle)
    }

    func testNewSessionIsCommandN() {
        XCTAssertEqual(command("n", [.command]), .newSession)
    }

    func testOpenSettingsIsCommandComma() {
        XCTAssertEqual(command(",", [.command]), .openSettings)
        XCTAssertNil(command(",", []))
        XCTAssertNil(command(",", [.command, .shift]))
    }

    func testSendDraftIsCommandReturnAndKeypadEnter() {
        XCTAssertEqual(command("\r", [.command]), .sendDraft)
        XCTAssertEqual(command("\u{3}", [.command]), .sendDraft)
    }

    func testPlainKeysPassThrough() {
        XCTAssertNil(command("d", []))
        XCTAssertNil(command("n", []))
        XCTAssertNil(command("\r", []))          // plain Return submits the field
        XCTAssertNil(command("\r", [.shift]))
    }

    func testExtraModifiersMakeChordNotOurs() {
        XCTAssertNil(command("d", [.command, .option]))
        XCTAssertNil(command("d", [.command, .control]))
        XCTAssertNil(command("n", [.command, .shift]))
        XCTAssertNil(command("\r", [.command, .shift]))
    }

    func testDeviceDependentFlagsAreIgnored() {
        // Caps Lock / fn / numeric-pad flags must not defeat a match.
        XCTAssertEqual(command("d", [.command, .capsLock]), .dictateToggle)
        XCTAssertEqual(command("\u{3}", [.command, .numericPad, .function]), .sendDraft)
    }

    func testUnrelatedKeysPassThrough() {
        XCTAssertNil(command("a", [.command]))
        XCTAssertNil(command("q", [.command]))
    }
}
