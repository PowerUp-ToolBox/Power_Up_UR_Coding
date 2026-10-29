import XCTest
@testable import PowerUp

/// Pins the stream-json wire protocol quirks that were verified live against
/// claude CLI v2.1.243 (see DESIGN.md). If a CLI update changes any of these
/// shapes, these tests are the first thing that should notice. Since slice
/// 2.3 the parser and the line splitter run in the Rust core, so these tests
/// play the lines through the bridge (`ClaudeService.events(fromLine:)` and
/// `IOChannel` are thin wrappers over it).
final class ClaudeStreamParsingTests: XCTestCase {

    private func parse(_ json: String) -> [ClaudeEvent] {
        ClaudeService.events(fromLine: Data(json.utf8))
    }

    // MARK: system/init

    func testSystemInitProducesReady() {
        let events = parse(#"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-sonnet-5","cwd":"/tmp"}"#)
        XCTAssertEqual(events, [.ready(sessionID: "abc-123", model: "claude-sonnet-5")])
    }

    func testSystemInitWithoutSessionIDIsIgnored() {
        XCTAssertEqual(parse(#"{"type":"system","subtype":"init","model":"m"}"#), [])
    }

    func testNonInitSystemSubtypesAreIgnored() {
        for subtype in ["status", "hook_started", "hook_response", "thinking_tokens", "api_retry", "compact_boundary"] {
            XCTAssertEqual(parse(#"{"type":"system","subtype":"\#(subtype)"}"#), [], "system/\(subtype) should be ignored")
        }
    }

    // MARK: stream_event deltas

    func testTextDelta() {
        let events = parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#)
        XCTAssertEqual(events, [.textDelta("Hello")])
    }

    func testNonTextDeltasAreIgnored() {
        for deltaType in ["thinking_delta", "signature_delta", "input_json_delta"] {
            let events = parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"\#(deltaType)","text":"x"}}}"#)
            XCTAssertEqual(events, [], "\(deltaType) should be ignored")
        }
    }

    func testOtherStreamEventSubtypesAreIgnored() {
        for eventType in ["message_start", "content_block_start", "content_block_stop", "message_delta", "message_stop"] {
            XCTAssertEqual(parse(#"{"type":"stream_event","event":{"type":"\#(eventType)"}}"#), [])
        }
    }

    // MARK: assistant messages

    func testAssistantThinkingOnlyBlockProducesNothing() {
        // Verified quirk: assistant messages arrive once per completed content
        // block — the first often carries only a thinking block.
        let events = parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}"#)
        XCTAssertEqual(events, [])
    }

    func testAssistantTextBlocksAreJoined() {
        let events = parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Part one."},{"type":"text","text":"Part two."}]}}"#)
        XCTAssertEqual(events, [.assistantMessage("Part one.\nPart two.")])
    }

    func testAssistantStringContentIsAccepted() {
        // Verified quirk: after set_model the CLI emits messages whose content
        // is a plain STRING, not an array — the parser must not assume array.
        let events = parse(#"{"type":"assistant","message":{"content":"plain string reply"}}"#)
        XCTAssertEqual(events, [.assistantMessage("plain string reply")])
    }

    func testUserEchoWithStringContentIsIgnored() {
        let events = parse(#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to sonnet</local-command-stdout>"}}"#)
        XCTAssertEqual(events, [])
    }

    func testToolUseProducesToolEventWithDetail() {
        let events = parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/main.py","other":"x"}}]}}"#)
        XCTAssertEqual(events, [.toolUse(name: "Edit", detail: "src/main.py")])
    }

    func testToolDetailIsCondensedAndTruncated() {
        let long = String(repeating: "a", count: 200)
        let events = parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\#(long)"}}]}}"#)
        guard case .toolUse(_, let detail)? = events.first else {
            return XCTFail("expected a toolUse event, got \(events)")
        }
        XCTAssertEqual(detail.count, 80)
        XCTAssertTrue(detail.hasSuffix("…"))
    }

    func testMixedTextAndToolBlocks() {
        let events = parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","name":"Write","input":{"file_path":"a.txt"}}]}}"#)
        XCTAssertEqual(events, [.assistantMessage("Editing now."), .toolUse(name: "Write", detail: "a.txt")])
    }

    // MARK: result

    func testSuccessResult() {
        let events = parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.042,"num_turns":3}"#)
        XCTAssertEqual(events, [.turnCompleted(resultText: "Done.", costUSD: 0.042, isError: false, subtype: "success")])
    }

    func testErrorSubtypeIsFlaggedEvenWithoutIsError() {
        let events = parse(#"{"type":"result","subtype":"error_during_execution","is_error":false,"result":"boom"}"#)
        XCTAssertEqual(events, [.turnCompleted(resultText: "boom", costUSD: nil, isError: true, subtype: "error_during_execution")])
    }

    func testEmptyResultTextBecomesNil() {
        let events = parse(#"{"type":"result","subtype":"success","is_error":false,"result":"   "}"#)
        XCTAssertEqual(events, [.turnCompleted(resultText: nil, costUSD: nil, isError: false, subtype: "success")])
    }

    // MARK: control_response

    func testControlResponseSuccessCarriesRequestID() {
        // At the parse layer `action` carries the raw request_id; the main
        // actor swaps in the recorded subtype.
        let events = parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"R2"}}"#)
        XCTAssertEqual(events, [.controlResult(action: "R2", ok: true, detail: "", value: nil)])
    }

    func testControlResponseErrorCarriesDetail() {
        let events = parse(#"{"type":"control_response","response":{"subtype":"error","request_id":"R9","error":"Unsupported control request subtype: set_effort"}}"#)
        XCTAssertEqual(events, [.controlResult(action: "R9", ok: false, detail: "Unsupported control request subtype: set_effort", value: nil)])
    }

    func testControlResponseWithoutRequestIDIsIgnored() {
        XCTAssertEqual(parse(#"{"type":"control_response","response":{"subtype":"success"}}"#), [])
    }

    // MARK: garbage tolerance

    func testUnknownTypesAndGarbageAreIgnored() {
        XCTAssertEqual(parse(#"{"type":"rate_limit_event","info":{}}"#), [])
        XCTAssertEqual(parse(#"{"type":"something_new_from_a_future_cli"}"#), [])
        XCTAssertEqual(parse(#"{"no_type_at_all":true}"#), [])
        XCTAssertEqual(parse("not json at all"), [])
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("[1,2,3]"), [])
    }

    // MARK: IOChannel line splitting

    func testPartialLinesWaitForMoreData() {
        let io = IOChannel()
        XCTAssertEqual(io.ingestStdout(Data(#"{"type":"sys"#.utf8)), [])
        let lines = io.ingestStdout(Data("tem\"}\n{\"a\":1}\n{\"partial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) },
                       [#"{"type":"system"}"#, #"{"a":1}"#])
        XCTAssertEqual(io.flushStdoutRemainder().map { String(decoding: $0, as: UTF8.self) }, #"{"partial"#)
        XCTAssertNil(io.flushStdoutRemainder())
    }

    func testEmptyLinesAreDropped() {
        let io = IOChannel()
        XCTAssertEqual(io.ingestStdout(Data("\n\n{\"x\":1}\n\n".utf8)).count, 1)
    }

    /// HK-053: a line that grows past 16 MiB without a newline is dropped
    /// instead of growing the buffer without bound. Whatever of it arrives
    /// after the drop becomes a garbage line of its own, which the parser
    /// ignores, and the next real line still parses.
    func testRunawayLineIsDiscarded() {
        let megabyte = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)

        let dropped = IOChannel()
        for _ in 0..<16 { XCTAssertEqual(dropped.ingestStdout(megabyte), []) }
        XCTAssertEqual(dropped.ingestStdout(megabyte), [])
        XCTAssertNil(dropped.flushStdoutRemainder(), "a tail past 16 MiB must be dropped")

        let kept = IOChannel()
        for _ in 0..<16 { XCTAssertEqual(kept.ingestStdout(megabyte), []) }
        XCTAssertEqual(kept.flushStdoutRemainder()?.count, 16 * 1024 * 1024, "exactly 16 MiB is kept")

        let io = IOChannel()
        for _ in 0..<17 { XCTAssertEqual(io.ingestStdout(megabyte), []) }
        let initLine = #"{"type":"system","subtype":"init","session_id":"s","model":"m"}"#
        let lines = io.ingestStdout(Data("xxx\n\(initLine)\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["xxx", initLine])
        XCTAssertEqual(lines.flatMap { ClaudeService.events(fromLine: $0) }, [.ready(sessionID: "s", model: "m")])
    }

    func testStderrTailIsBoundedAndPrefixed() {
        let io = IOChannel()
        io.ingestStderr(Data(String(repeating: "e", count: 1000).utf8))
        let tail = io.stderrTail(maxChars: 100)
        XCTAssertEqual(tail.count, 101)
        XCTAssertTrue(tail.hasPrefix("…"))
    }
}
