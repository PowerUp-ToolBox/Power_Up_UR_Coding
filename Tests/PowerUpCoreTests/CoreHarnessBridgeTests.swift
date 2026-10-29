import XCTest
import PowerUpCore

/// The Claude harness half of the bridge (slice 2.3): the first uniffi
/// object, `CoreLineBuffer`, keeps its tail between calls and can be fed
/// from the pipe reader threads, and the line parser answers through the
/// generated functions.
final class CoreHarnessBridgeTests: XCTestCase {

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    func testTheLineBufferKeepsItsTailBetweenCalls() throws {
        let buffer = try CoreLineBuffer()
        XCTAssertEqual(try buffer.ingest(chunk: Data(#"{"type":"sys"#.utf8)), [])
        let lines = try buffer.ingest(chunk: Data("tem\"}\n\n{\"a\":1}\r\n{\"partial".utf8))
        XCTAssertEqual(lines.map(text), [#"{"type":"system"}"#, "{\"a\":1}\r"])
        XCTAssertEqual(try buffer.flushRemainder().map(text), #"{"partial"#)
        XCTAssertNil(try buffer.flushRemainder())
    }

    /// Each launch's stdout and its termination drain run on GCD threads;
    /// two launches can overlap while the old one shuts down. Buffers are
    /// independent and each one is safe to call from any thread.
    func testBuffersAreFedFromSeveralThreadsAtOnce() throws {
        let buffers = [try CoreLineBuffer(), try CoreLineBuffer()]
        let rounds = 500
        var collected = [[String]](repeating: [], count: buffers.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: buffers.count) { index in
            var mine: [String] = []
            for round in 0..<rounds {
                // Each line arrives in two chunks, so the tail must survive.
                let line = #"{"buffer":\#(index),"round":\#(round)}"#
                let cut = line.index(line.startIndex, offsetBy: 5)
                mine += ((try? buffers[index].ingest(chunk: Data(line[..<cut].utf8))) ?? []).map(text)
                mine += ((try? buffers[index].ingest(chunk: Data((line[cut...] + "\n").utf8))) ?? []).map(text)
            }
            lock.lock()
            collected[index] = mine
            lock.unlock()
        }
        for index in buffers.indices {
            XCTAssertEqual(collected[index], (0..<rounds).map { #"{"buffer":\#(index),"round":\#($0)}"# })
            XCTAssertNil(try buffers[index].flushRemainder())
        }
    }

    func testOneLineParsesThroughTheBridge() throws {
        let line = Data(#"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-sonnet-5"}"#.utf8)
        XCTAssertEqual(try claudeEventsFromLine(line: line), [.ready(sessionId: "abc-123", model: "claude-sonnet-5")])
        XCTAssertEqual(try claudeEventsFromLine(line: Data("not json".utf8)), [])
    }

    // MARK: The Claude adapter object

    private let configuration = CoreHarnessConfiguration(projectDir: "/work/app", model: "default",
                                                         permissionMode: "acceptEdits", effort: "default",
                                                         resumeSessionId: nil, binaryPathOverride: "/opt/claude",
                                                         agentCommand: nil)

    func testAStartPublishesStartingAndAsksForTheBinary() throws {
        let adapter = try CoreClaudeAdapter(requestIdPrefix: "R")
        XCTAssertEqual(try adapter.start(configuration: configuration), [
            .publish(snapshot: CoreClaudeSnapshot(state: .starting, sessionId: nil, modelName: nil, totalCostUsd: 0)),
            .resolveBinary(generation: 1, binaryPathOverride: "/opt/claude")
        ])
        XCTAssertEqual(try adapter.generation(), 1)
    }

    /// The adapter keeps its state between calls: the queue before the
    /// spawn, the generation, the request ids.
    func testTheAdapterKeepsItsStateAcrossCalls() throws {
        let adapter = try CoreClaudeAdapter(requestIdPrefix: "R")
        _ = try adapter.start(configuration: configuration)
        XCTAssertEqual(try adapter.setModel(model: "sonnet", processRunning: false), [])
        guard case .spawn(1, "/opt/claude", let arguments, "/work/app")? =
                try adapter.binaryResolved(generation: 1, path: "/opt/claude").first else {
            return XCTFail("no spawn")
        }
        XCTAssertTrue(arguments.contains("--verbose"))
        let flushed = try adapter.spawned(generation: 1)
        guard case .writeStdin(let line)? = flushed.first, flushed.count == 1 else {
            return XCTFail("the queued request was not flushed: \(flushed)")
        }
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(request["request_id"] as? String, "R-1")
        XCTAssertNil(request["subtype"], "the flat shape kills the CLI")

        // The ack refreshes the model; a retired generation's line is dropped.
        let ack = try claudeEventsFromLine(line: Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"R-1"}}"#.utf8))
        XCTAssertEqual(try adapter.stdoutEvent(generation: 0, event: ack[0]), [])
        XCTAssertEqual(try adapter.stdoutEvent(generation: 1, event: ack[0]), [
            .publish(snapshot: CoreClaudeSnapshot(state: .starting, sessionId: nil, modelName: "sonnet", totalCostUsd: 0)),
            .emit(event: .controlResult(action: "set_model", ok: true, detail: "", value: "sonnet"))
        ])
    }

    func testTheStdinAndLaunchFunctionsAnswer() throws {
        XCTAssertNil(try claudeUserTurnLine(text: "  "))
        XCTAssertEqual(try claudeUserTurnLine(text: " Hi ")?.last, 0x0A)
        XCTAssertNil(try claudeControlRequestLine(requestId: "R-1", subtype: "set_model", value: " "))
        XCTAssertThrowsError(try claudeControlRequestLine(requestId: "R-1", subtype: "set_effort", value: "low"))
        XCTAssertEqual(try claudeLaunchArguments(model: "opus", permissionMode: "", effort: "max",
                                                 resumeSessionId: " s "),
                       ["-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--include-partial-messages", "--model", "opus", "--effort", "max", "--resume", "s"])
        XCTAssertEqual(try harnessEventFromClaude(event: .terminated(exitCode: 3)), .ended(exitCode: 3))
    }
}
