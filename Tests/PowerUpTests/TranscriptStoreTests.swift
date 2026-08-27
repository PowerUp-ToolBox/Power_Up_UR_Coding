import XCTest
@testable import PowerUp

/// Exercises transcript persistence against a temp directory via the
/// support-directory override — a live installation's history is never touched.
@MainActor
final class TranscriptStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TranscriptStore.supportDirectoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        TranscriptStore.supportDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(project: String = "/tmp/projects/demo") -> TranscriptStore {
        let store = TranscriptStore()
        store.setProject(project)
        return store
    }

    // MARK: Round trip

    func testAppendAndLoadRoundTrip() {
        let store = makeStore()
        let entries = [
            TranscriptEntry(kind: .user, text: "Run the tests"),
            TranscriptEntry(kind: .assistant, text: "All 66 tests pass."),
            TranscriptEntry(kind: .tool, text: "Bash — swift test"),
            TranscriptEntry(kind: .system, text: "Session started (sonnet)"),
            TranscriptEntry(kind: .error, text: "boom"),
        ]
        for entry in entries { store.append(entry) }

        let loaded = store.loadTail()
        XCTAssertEqual(loaded.count, entries.count)
        for (got, expected) in zip(loaded, entries) {
            XCTAssertEqual(got.id, expected.id)
            XCTAssertEqual(got.kind, expected.kind)
            XCTAssertEqual(got.text, expected.text)
            // JSON round-trips the date as a floating-point number of seconds —
            // sub-second precision may wobble in the last bits, and that's fine.
            XCTAssertEqual(got.date.timeIntervalSince1970,
                           expected.date.timeIntervalSince1970, accuracy: 0.01)
        }
    }

    func testEntriesSurviveAcrossStoreInstances() {
        makeStore().append(TranscriptEntry(kind: .user, text: "hello"))
        let loaded = makeStore().loadTail()
        XCTAssertEqual(loaded.map(\.text), ["hello"])
    }

    // MARK: Isolation and lifecycle

    func testDistinctProjectsGetDistinctFiles() {
        let a = makeStore(project: "/tmp/work/api")
        let b = makeStore(project: "/tmp/personal/api")   // same basename, different path
        XCTAssertNotEqual(TranscriptStore.fileURL(forProjectDir: "/tmp/work/api"),
                          TranscriptStore.fileURL(forProjectDir: "/tmp/personal/api"))

        a.append(TranscriptEntry(kind: .user, text: "for a"))
        b.append(TranscriptEntry(kind: .user, text: "for b"))
        XCTAssertEqual(a.loadTail().map(\.text), ["for a"])
        XCTAssertEqual(b.loadTail().map(\.text), ["for b"])
    }

    func testFileURLIsStableForAPath() {
        XCTAssertEqual(TranscriptStore.fileURL(forProjectDir: "/tmp/work/api"),
                       TranscriptStore.fileURL(forProjectDir: "/tmp/work/api"))
    }

    func testNoProjectMeansNoPersistence() {
        let store = TranscriptStore()
        store.append(TranscriptEntry(kind: .user, text: "goes nowhere"))
        XCTAssertEqual(store.loadTail(), [])
        store.setProject("")
        store.append(TranscriptEntry(kind: .user, text: "still nowhere"))
        XCTAssertEqual(store.loadTail(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptStore.transcriptsDirectory.path))
    }

    // MARK: Tolerance

    func testCorruptAndUnknownLinesAreSkipped() throws {
        let store = makeStore()
        store.append(TranscriptEntry(kind: .user, text: "first"))

        let url = TranscriptStore.fileURL(forProjectDir: store.projectDir!)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n{\"future\":\"shape\"}\n".utf8))
        try handle.close()

        store.append(TranscriptEntry(kind: .assistant, text: "second"))
        XCTAssertEqual(store.loadTail().map(\.text), ["first", "second"])
    }

    // MARK: Limits

    func testLoadTailReturnsNewestEntriesOldestFirst() {
        let store = makeStore()
        for i in 1...30 {
            store.append(TranscriptEntry(kind: .user, text: "message \(i)"))
        }
        let tail = store.loadTail(maxEntries: 10)
        XCTAssertEqual(tail.map(\.text), (21...30).map { "message \($0)" })
    }

    func testOvergrownFileIsCompactedOnLoad() throws {
        let store = makeStore()
        let extra = 50
        for i in 1...(TranscriptStore.maxStoredEntries + extra) {
            store.append(TranscriptEntry(kind: .user, text: "m\(i)"))
        }

        let tail = store.loadTail(maxEntries: 5)
        XCTAssertEqual(tail.map(\.text),
                       ((TranscriptStore.maxStoredEntries + extra - 4)...(TranscriptStore.maxStoredEntries + extra)).map { "m\($0)" })

        let url = TranscriptStore.fileURL(forProjectDir: store.projectDir!)
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        XCTAssertEqual(lines.count, TranscriptStore.maxStoredEntries,
                       "loading an overgrown file must rewrite it down to maxStoredEntries")
    }

    // MARK: Format

    func testOnDiskFormatIsOneJSONObjectPerLine() throws {
        let store = makeStore()
        store.append(TranscriptEntry(kind: .user, text: "line one\nwith a newline inside"))
        store.append(TranscriptEntry(kind: .assistant, text: "reply"))

        let url = TranscriptStore.fileURL(forProjectDir: store.projectDir!)
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2, "embedded newlines must be escaped, one entry per line")
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            XCTAssertNotNil(object?["id"])
            XCTAssertNotNil(object?["kind"])
            XCTAssertNotNil(object?["text"])
            XCTAssertNotNil(object?["date"])
        }
    }
}
