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
}
