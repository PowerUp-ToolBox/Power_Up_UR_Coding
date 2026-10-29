import XCTest
@testable import PowerUp

/// Plays the four `Tests/Fixtures/transcript/` tables through the real
/// `TranscriptStore` in a temporary support directory: a line or a whole
/// file is written where the store reads it and loaded with `loadTail`, an
/// entry is appended and the written line read back, and a project path is
/// turned into its file name. A live installation's history is never touched.
@MainActor
final class TranscriptFixtureTests: XCTestCase {

    private var tempDir: URL!

    /// The project every table's file belongs to.
    private static let project = "/tmp/powerup-transcript-fixture-project"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-transcript-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TranscriptStore.supportDirectoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        TestSandbox.parkOverrides()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: lines.json

    func testTranscriptLineTable() throws {
        let fileName = "lines.json"
        let file = try TextSafetyFixtures.load(fileName, area: "transcript",
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let line = try FixtureLine.bytes(fixtureCase.input)
            XCTAssertFalse(line.contains(0x0A), "\(fileName) case \(fixtureCase.name): a line holds no LF")
            let loaded = try load(file: line + Data([0x0A]), maxEntries: TranscriptStore.defaultRestoreCount).entries
            XCTAssertLessThanOrEqual(loaded.count, 1, "\(fileName) case \(fixtureCase.name)")
            let actual = loaded.first.map { Self.descriptor($0, expectedDate: fixtureCase.expected["date"]) } ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: encode.json

    func testTranscriptEncodeTable() throws {
        let fileName = "encode.json"
        let file = try TextSafetyFixtures.load(fileName, area: "transcript",
                                               input: JSONValue.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let entry = try Self.entry(fixtureCase.input)
            XCTAssertEqual(entry.id.uuidString, fixtureCase.input["id"]?.stringValue,
                           "\(fileName) case \(fixtureCase.name): ids are written as uuidString writes them")
            let seconds = try XCTUnwrap(Self.seconds(fixtureCase.input["date"]))
            XCTAssertEqual(entry.date.timeIntervalSince1970, seconds,
                           "\(fileName) case \(fixtureCase.name): the date must be one a Date holds exactly")
            let actual = try appendedLine(entry)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: load.json

    func testTranscriptLoadTable() throws {
        let fileName = "load.json"
        let file = try TextSafetyFixtures.load(fileName, area: "transcript",
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let bytes = try FixtureLine.bytes(try XCTUnwrap(fixtureCase.input["file"]))
            guard case .integer(let maxEntries)? = fixtureCase.input["maxEntries"] else {
                XCTFail("\(fileName) case \(fixtureCase.name): maxEntries must be an integer")
                continue
            }
            let (entries, rewritten) = try load(file: bytes, maxEntries: Int(maxEntries))
            let actual: JSONValue = .object([
                "texts": .array(entries.map { .string($0.text) }),
                "rewrite": .bool(rewritten),
            ])
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: file-name.json

    func testTranscriptFileNameTable() throws {
        let fileName = "file-name.json"
        let file = try TextSafetyFixtures.load(fileName, area: "transcript",
                                               input: String.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            // Scalar for scalar: String's == would let a precomposed accent
            // pass, and the platform's standardizing decomposes it.
            let standardized = URL(fileURLWithPath: fixtureCase.input, isDirectory: true).standardizedFileURL.path
            XCTAssertEqual(Array(standardized.unicodeScalars), Array(fixtureCase.input.unicodeScalars),
                           "\(fileName) case \(fixtureCase.name): every input must already be standardized")
            let actual = try XCTUnwrap(TranscriptStore.fileURL(forProjectDir: fixtureCase.input)).lastPathComponent
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: Helpers

    /// Writes `file` where the store reads the project's transcript, loads it,
    /// and says whether loading rewrote the bytes.
    private func load(file: Data, maxEntries: Int) throws -> (entries: [TranscriptEntry], rewritten: Bool) {
        let url = try XCTUnwrap(TranscriptStore.fileURL(forProjectDir: Self.project))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptStore()
        store.setProject(Self.project)
        let entries = store.loadTail(maxEntries: maxEntries)
        return (entries, try Data(contentsOf: url) != file)
    }

    /// The line `append` writes for `entry` into an empty file, without its LF.
    private func appendedLine(_ entry: TranscriptEntry) throws -> String {
        let url = try XCTUnwrap(TranscriptStore.fileURL(forProjectDir: Self.project))
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptStore()
        store.setProject(Self.project)
        store.append(entry)
        let text = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"), "an appended line ends with LF")
        return String(text.dropLast())
    }

    /// The entry descriptor of `entry`. The date is the expected seconds when
    /// they build the very Date the entry holds (the app keeps a Date, not
    /// the number that was read).
    private static func descriptor(_ entry: TranscriptEntry, expectedDate: JSONValue?) -> JSONValue {
        var date = JSONValue.number(entry.date.timeIntervalSince1970)
        if let expectedDate, let seconds = seconds(expectedDate),
           Date(timeIntervalSince1970: seconds) == entry.date {
            date = expectedDate
        }
        return .object([
            "id": .string(entry.id.uuidString),
            "kind": .string(entry.kind.rawValue),
            "text": .string(entry.text),
            "date": date,
        ])
    }

    /// A transcript entry descriptor as the app's entry.
    private static func entry(_ descriptor: JSONValue) throws -> TranscriptEntry {
        guard let idText = descriptor["id"]?.stringValue, let id = UUID(uuidString: idText),
              let kindName = descriptor["kind"]?.stringValue,
              let kind = TranscriptEntry.Kind(rawValue: kindName),
              let text = descriptor["text"]?.stringValue,
              let seconds = seconds(descriptor["date"]) else {
            throw FixtureValueError(description: "not a transcript entry: \(descriptor)")
        }
        return TranscriptEntry(id: id, kind: kind, text: text, date: Date(timeIntervalSince1970: seconds))
    }

    private static func seconds(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let whole)?: return Double(whole)
        case .number(let seconds)?: return seconds
        default: return nil
        }
    }
}
