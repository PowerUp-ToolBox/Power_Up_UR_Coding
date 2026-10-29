import XCTest
@testable import PowerUp

/// Plays the five `Tests/Fixtures/hooks/` tables through `HookInstaller`.
/// Every settings file is a temporary one passed as `settingsURL:`, and the
/// support directory is pointed at the fixture script path's folder (under
/// /tmp, removed afterwards), so the real `~/.claude/settings.json` and a
/// live PowerUp installation are never touched.
final class HookFixtureTests: XCTestCase {

    private var tempDir: URL!
    private var settingsURL: URL!
    /// The folders under /tmp that the tables' writing cases name for the
    /// hook script; the old installer writes the script there, so they are
    /// removed after every test.
    private static let scriptRoots = ["/tmp/PowerUp Hook Fixture", "/tmp/PowerUp Hook's Fixture"]

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-hook-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        TestSandbox.parkHookInstallerOverrides()
        try? FileManager.default.removeItem(at: tempDir)
        for root in Self.scriptRoots {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    // MARK: command.json

    func testHookCommandTable() throws {
        let fileName = "command.json"
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: String.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            try useScriptPath(fixtureCase.input, writes: false)
            let actual = HookInstaller.hookCommand()
            XCTAssertEqual(Array(actual.unicodeScalars), Array(fixtureCase.expected.unicodeScalars),
                           "\(fileName) case \(fixtureCase.name)")
        }
    }

    // MARK: script.json

    func testHookScriptTable() throws {
        let fileName = "script.json"
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: JSONValue.self, expected: [String].self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let body = try Self.scriptBody(fixtureCase.input)
            XCTAssertEqual(Data(body.utf8), Self.fileBytes(lines: fixtureCase.expected),
                           "\(fileName) case \(fixtureCase.name): \(TextSafetyFixtures.debugDescription(body))")
        }
    }

    // MARK: install.json and uninstall.json

    func testHookInstallTable() throws {
        try playEditTable("install.json") { try HookInstaller.install(port: 48738, token: "tok", settingsURL: $0) }
    }

    func testHookUninstallTable() throws {
        try playEditTable("uninstall.json") { try HookInstaller.uninstall(settingsURL: $0) }
    }

    // MARK: install-state.json

    func testHookInstallStateTable() throws {
        let fileName = "install-state.json"
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try installStateOutcome(fixtureCase.input)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: Helpers

    /// `{installState, isInstalled}` for one case: the settings and the
    /// script written to temporary files, then both questions asked.
    func installStateOutcome(_ input: JSONValue) throws -> JSONValue {
        try useScriptPath(try XCTUnwrap(input["scriptPath"]?.stringValue), writes: true)
        try placeSettings(Self.fileInput(input["settings"]))
        let scriptURL = HookInstaller.hookScriptURL()
        try? FileManager.default.removeItem(at: scriptURL)
        if let script = try Self.scriptInput(input["scriptOnDisk"]) {
            try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try script.write(to: scriptURL)
        }
        let port = try Self.integer(input["port"])
        let token = try XCTUnwrap(input["token"]?.stringValue)
        let state = HookInstaller.installState(port: port, token: token, settingsURL: settingsURL)
        return .object([
            "installState": .string(Self.name(state)),
            "isInstalled": .bool(HookInstaller.isInstalled(settingsURL: settingsURL)),
        ])
    }

    /// Runs `edit` on each case's settings file and describes what it did:
    /// written (the exact bytes), left unchanged, or refused.
    private func playEditTable(_ fileName: String, edit: (URL) throws -> Void) throws {
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try editOutcome(fixtureCase.input, edit: edit)
            let expected = fixtureCase.expected
            if case .object(var expectedFields) = expected, case .array(let lines)? = expectedFields["file"],
               case .object(var actualFields) = actual, case .string(let written)? = actualFields["bytes"] {
                // The file is compared byte for byte, not as a Swift String.
                let wanted = Self.fileBytes(lines: lines.compactMap(\.stringValue))
                XCTAssertEqual(Data(written.utf8), wanted, "\(fileName) case \(fixtureCase.name): \(written)")
                expectedFields["file"] = nil
                actualFields["bytes"] = nil
                XCTAssertEqual(JSONValue.object(actualFields), JSONValue.object(expectedFields),
                               "\(fileName) case \(fixtureCase.name)")
                continue
            }
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// `{"outcome": "write", "bytes": <the file written>}`,
    /// `{"outcome": "unchanged"}` or `{"outcome": "refused", …}`.
    func editOutcome(_ input: JSONValue, edit: (URL) throws -> Void) throws -> JSONValue {
        try useScriptPath(try XCTUnwrap(input["scriptPath"]?.stringValue), writes: true)
        let before = try Self.fileInput(input["settings"])
        try placeSettings(before)
        do {
            try edit(settingsURL)
        } catch let error as HookInstaller.HookError {
            XCTAssertEqual(try? Data(contentsOf: settingsURL), before, "a refused edit must leave the file as it was")
            return Self.refusal(error, path: settingsURL.path)
        }
        let after = try? Data(contentsOf: settingsURL)
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.powerup-backup-1")
        if after == before, !FileManager.default.fileExists(atPath: backup.path) {
            return .object(["outcome": .string("unchanged")])
        }
        let written = try XCTUnwrap(after)
        return .object(["outcome": .string("write"),
                        "bytes": .string(String(decoding: written, as: UTF8.self))])
    }

    static func refusal(_ error: HookInstaller.HookError, path: String) -> JSONValue {
        switch error {
        case .invalidSettings:
            return .object(["outcome": .string("refused"), "refusal": .string("invalidJSON")])
        case .unexpectedShape(let detail):
            if detail == "The \"hooks\" section of \(path) isn't in the expected format, so PowerUp left it alone." {
                return .object(["outcome": .string("refused"), "refusal": .string("hooksNotAnObject")])
            }
            for event in HookInstaller.hookEvents
            where detail == "The \"\(event)\" hooks in \(path) aren't in the expected format, so PowerUp left them alone." {
                return .object(["outcome": .string("refused"), "refusal": .string("eventNotAnArray"),
                                "event": .string(event)])
            }
            return .object(["outcome": .string("unexpected"), "detail": .string(detail)])
        case .fileError(let detail):
            return .object(["outcome": .string("fileError"), "detail": .string(detail)])
        }
    }

    /// Points the support directory at the folder of `path`, which must end
    /// in the script's own name. A case that may write the script must name
    /// a path under one of `scriptRoots`.
    private func useScriptPath(_ path: String, writes: Bool) throws {
        let url = URL(fileURLWithPath: path)
        XCTAssertEqual(url.lastPathComponent, "powerup-hook.sh", "fixture script paths name the hook script")
        if writes {
            guard Self.scriptRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
                throw FixtureValueError(description: "a writing case's script path must be under \(Self.scriptRoots)")
            }
        }
        HookInstaller.supportDirectoryOverride = url.deletingLastPathComponent()
        XCTAssertEqual(Array(HookInstaller.hookScriptURL().path.unicodeScalars), Array(path.unicodeScalars))
    }

    private func placeSettings(_ data: Data?) throws {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: item)
        }
        if let data { try data.write(to: settingsURL) }
    }

    /// A file input: null (no file), a string or `{"hex": …}`.
    static func fileInput(_ descriptor: JSONValue?) throws -> Data? {
        guard let descriptor, descriptor != .null else { return nil }
        return try FixtureLine.bytes(descriptor)
    }

    /// The script on disk: a file input, or the body `scriptFor` names
    /// (without its last byte for `scriptForWithoutTrailingNewline`).
    static func scriptInput(_ descriptor: JSONValue?) throws -> Data? {
        if let spec = descriptor?["scriptFor"] {
            return Data(try scriptBody(spec).utf8)
        }
        if let spec = descriptor?["scriptForWithoutTrailingNewline"] {
            return Data(try scriptBody(spec).utf8).dropLast()
        }
        return try fileInput(descriptor)
    }

    static func scriptBody(_ spec: JSONValue) throws -> String {
        HookInstaller.hookScriptBody(port: try integer(spec["port"]),
                                     token: try XCTUnwrap(spec["token"]?.stringValue))
    }

    static func integer(_ value: JSONValue?) throws -> Int {
        guard case .integer(let number)? = value else {
            throw FixtureValueError(description: "not an integer: \(String(describing: value))")
        }
        return Int(number)
    }

    /// The bytes of a "file lines" descriptor.
    static func fileBytes(lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    static func name(_ state: HookInstaller.InstallState) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .installed: return "installed"
        case .outOfDate: return "outOfDate"
        }
    }
}
