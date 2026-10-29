import XCTest
import PowerUpCore

/// The transcript half of the bridge (slice 2.5): an enum with an `error`
/// case, a record with a Double, bytes both ways and an optional byte
/// buffer, all through the generated functions.
final class CoreTranscriptBridgeTests: XCTestCase {

    private let entry = CoreTranscriptEntry(id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", kind: .error,
                                            text: "boom /x", dateSeconds: 1761700000.5)

    func testALineLoadsBack() throws {
        let line = try transcriptLine(entry: entry)
        XCTAssertEqual(String(decoding: line, as: UTF8.self),
                       #"{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","kind":"error","text":"boom \/x","date":1761700000.5}"#
                       + "\n")
        let load = try transcriptLoad(bytes: line + Data("not json\n".utf8), maxEntries: 200)
        XCTAssertEqual(load.entries, [entry])
        XCTAssertNil(load.rewrite)
    }

    func testAnOvergrownFileComesBackWithItsRewrite() throws {
        let line = try transcriptLine(entry: entry)
        let file = (0..<2001).reduce(into: Data()) { data, _ in data += line }
        let load = try transcriptLoad(bytes: file, maxEntries: 1)
        XCTAssertEqual(load.entries, [entry])
        XCTAssertEqual(load.rewrite?.count, line.count * 2000)
    }

    func testNamesAndLimits() throws {
        XCTAssertEqual(try transcriptFileName(standardizedPath: "/tmp/work/api"), "api-ad9243f90664.jsonl")
        let limits = try transcriptLimits()
        XCTAssertEqual(limits.maxStoredEntries, 2000)
        XCTAssertEqual(limits.defaultRestoreCount, 200)
    }
}
