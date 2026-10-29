import XCTest
import PowerUpCore

/// The text safety half of the bridge (slice 2.5): strings with line
/// breaks, combining marks and emoji both ways, a list of strings, a list of
/// records and a record with an Int64 in, all through the generated
/// functions. Only literal text is used; cmux is never run.
final class CoreTextSafetyBridgeTests: XCTestCase {

    func testDictatedTextCrossesFlatAndDefused() throws {
        XCTAssertEqual(try flattenLineBreaks(text: "one\r\ntwo\u{2028}three\n"), "one two three ")
        // A break a combining mark follows is still flattened: the rule is on scalars.
        XCTAssertEqual(Array(try flattenLineBreaks(text: "a\n\u{301}b").unicodeScalars),
                       Array("a \u{301}b".unicodeScalars))
        XCTAssertEqual(try escapeSafeSegments(text: "ls\nC:\\new\\temp 👩‍👩‍👧"),
                       ["ls C:\\", "new\\", "temp 👩‍👩‍👧"])
        XCTAssertEqual(try escapeSafeSegments(text: ""), [])
        XCTAssertEqual(try escapeSafeSegments(text: "\\n\u{301}"), ["\\n\u{301}"])
    }

    func testWorkspaceRowsCrossAsRecords() throws {
        let output = "* workspace:11  ⠐ Build PS5 controller voice app  [selected]\n"
            + "  workspace:7   ✳ Design the WeChat mini program\n"
            + "  3F2504E0-4F89-11D3-9A0C-0305E82C3301  ✅ 東京\n"
        XCTAssertEqual(try parseWorkspaces(output: output), [
            CoreCmuxWorkspace(reference: "workspace:11", title: "Build PS5 controller voice app", selected: true),
            CoreCmuxWorkspace(reference: "workspace:7", title: "Design the WeChat mini program", selected: false),
            CoreCmuxWorkspace(reference: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", title: "✅ 東京", selected: false)
        ])
        XCTAssertEqual(try parseWorkspaces(output: ""), [])
        XCTAssertEqual(try stripStatusGlyph(title: "⠋  Build app  "), "Build app")
        XCTAssertEqual(try stripStatusGlyph(title: "…/src/app"), "…/src/app")
    }

    func testFailuresCondenseAndClassify() throws {
        XCTAssertEqual(try condense(text: "a\n b\t\tc", maxChars: 10), "a b c")
        XCTAssertEqual(try condense(text: "東京都庁舎", maxChars: 3), "東京…")
        XCTAssertEqual(try condense(text: "", maxChars: Int64.min), "…")
        let refused = CoreCommandResult(status: 1, standardOutput: "", standardError: "write: Broken pipe",
                                        timedOut: false, spawnFailed: false)
        XCTAssertTrue(try failureMessage(action: "Sending text to cmux", result: refused)
            .hasPrefix("cmux refused the connection. In cmux, open Settings → Automation"))
        let silent = CoreCommandResult(status: Int64(Int32.min), standardOutput: "", standardError: "",
                                       timedOut: false, spawnFailed: false)
        XCTAssertEqual(try failureMessage(action: "Pressing Enter", result: silent),
                       "Pressing Enter failed (exit -2147483648).")
        let timedOut = CoreCommandResult(status: 0, standardOutput: "", standardError: "Socket not found",
                                         timedOut: true, spawnFailed: false)
        XCTAssertEqual(try failureMessage(action: "Reaching cmux", result: timedOut),
                       "Reaching cmux timed out — is the cmux app running?")
    }
}
