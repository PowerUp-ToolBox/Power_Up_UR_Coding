import XCTest
@testable import PowerUp

/// Plays the five `Tests/Fixtures/hooks/` tables through the bridge: the
/// core's decision for each settings file, and for a write the bytes
/// `HookInstaller`'s own writer makes of the core's JSON, compared byte for
/// byte. Everything is in memory: no settings file, no hook script, and so
/// never the real `~/.claude/settings.json` (HookInstallerTests drive the
/// same rules through temporary files).
final class HookFixtureTests: XCTestCase {

    // MARK: command.json

    func testHookCommandTable() throws {
        let fileName = "command.json"
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: String.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try XCTUnwrap(CoreBridge.hookCommand(scriptPath: fixtureCase.input))
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
        try playEditTable("install.json") { CoreBridge.hookInstallEdit(settings: $0, scriptPath: $1) }
    }

    func testHookUninstallTable() throws {
        try playEditTable("uninstall.json") { CoreBridge.hookUninstallEdit(settings: $0, scriptPath: $1) }
    }

    // MARK: install-state.json

    func testHookInstallStateTable() throws {
        let fileName = "install-state.json"
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let input = fixtureCase.input
            let settings = try Self.fileInput(input["settings"])
            let scriptPath = try XCTUnwrap(input["scriptPath"]?.stringValue)
            let state = CoreBridge.hookInstallState(settings: settings, scriptPath: scriptPath,
                                                    scriptOnDisk: try Self.scriptInput(input["scriptOnDisk"]),
                                                    port: try Self.integer(input["port"]),
                                                    token: try XCTUnwrap(input["token"]?.stringValue))
            let actual: JSONValue = .object([
                "installState": .string(Self.name(state)),
                "isInstalled": .bool(CoreBridge.hooksInstalled(settings: settings, scriptPath: scriptPath)),
            ])
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: Helpers

    /// Asks the core for each case's edit and describes it: a write as the
    /// exact bytes the app's writer makes of it, compared byte for byte.
    private func playEditTable(_ fileName: String,
                               edit: (Data?, String) -> CoreBridge.SettingsEdit?) throws {
        let file = try TextSafetyFixtures.load(fileName, area: "hooks", input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let settings = try Self.fileInput(fixtureCase.input["settings"])
            let scriptPath = try XCTUnwrap(fixtureCase.input["scriptPath"]?.stringValue)
            let actual: JSONValue
            switch edit(settings, scriptPath) {
            case .write(let json)?:
                guard case .array(let lines)? = fixtureCase.expected["file"] else {
                    XCTFail("\(fileName) case \(fixtureCase.name): the core wrote \(String(decoding: json, as: UTF8.self))")
                    continue
                }
                let written = try HookInstaller.settingsBytes(fromCoreJSON: json, path: "settings.json")
                XCTAssertEqual(written, Self.fileBytes(lines: lines.compactMap(\.stringValue)),
                               "\(fileName) case \(fixtureCase.name): \(String(decoding: written, as: UTF8.self))")
                actual = .object(["outcome": .string("write"), "file": .array(lines)])
            case .unchanged?:
                actual = .object(["outcome": .string("unchanged")])
            case .refused(let refusal)?:
                actual = Self.descriptor(refusal)
            case nil:
                XCTFail("\(fileName) case \(fixtureCase.name): the core failed")
                continue
            }
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    static func descriptor(_ refusal: CoreBridge.SettingsRefusal) -> JSONValue {
        switch refusal {
        case .invalidJSON:
            return .object(["outcome": .string("refused"), "refusal": .string("invalidJSON")])
        case .hooksNotAnObject:
            return .object(["outcome": .string("refused"), "refusal": .string("hooksNotAnObject")])
        case .eventNotAnArray(let event):
            return .object(["outcome": .string("refused"), "refusal": .string("eventNotAnArray"),
                            "event": .string(event)])
        }
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
        try XCTUnwrap(CoreBridge.hookScriptBody(port: try integer(spec["port"]),
                                                token: try XCTUnwrap(spec["token"]?.stringValue)))
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
