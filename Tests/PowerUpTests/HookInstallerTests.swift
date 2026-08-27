import XCTest
@testable import PowerUp

/// Exercises the settings.json merge logic against throwaway copies in a temp
/// directory. The support-directory override keeps the hook script away from
/// any live PowerUp installation; the real ~/.claude/settings.json is never
/// touched (the settings path is injected everywhere).
final class HookInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsURL = tempDir.appendingPathComponent("settings.json")
        HookInstaller.supportDirectoryOverride = tempDir.appendingPathComponent("support", isDirectory: true)
    }

    override func tearDownWithError() throws {
        HookInstaller.supportDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSettings(_ json: String) throws {
        try Data(json.utf8).write(to: settingsURL)
    }

    private func readSettingsObject() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(forEvent event: String, in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return [] }
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: Install

    func testInstallIntoMissingFileRegistersAllThreeEvents() throws {
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)

        let root = try readSettingsObject()
        for event in HookInstaller.hookEvents {
            XCTAssertEqual(commands(forEvent: event, in: root), [HookInstaller.hookCommand()],
                           "expected exactly our command under \(event)")
        }
        XCTAssertTrue(HookInstaller.isInstalled(settingsURL: settingsURL))
        XCTAssertEqual(HookInstaller.installState(port: 48738, token: "tok", settingsURL: settingsURL), .installed)
    }

    func testInstallIsIdempotent() throws {
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)

        let root = try readSettingsObject()
        for event in HookInstaller.hookEvents {
            XCTAssertEqual(commands(forEvent: event, in: root).count, 1,
                           "double install must leave exactly one entry under \(event)")
        }
    }

    func testInstallPreservesUnknownKeysAndForeignHooks() throws {
        try writeSettings(#"""
        {
          "model": "opus",
          "env": {"FOO": "bar"},
          "hooks": {
            "Stop": [{"matcher": "x", "hooks": [{"type": "command", "command": "/usr/bin/say done"}]}],
            "PreToolUse": [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]}]
          }
        }
        """#)

        try HookInstaller.install(port: 1234, token: "t", settingsURL: settingsURL)

        let root = try readSettingsObject()
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["env"] as? [String: Any])?["FOO"] as? String, "bar")
        XCTAssertEqual(commands(forEvent: "Stop", in: root), ["/usr/bin/say done", HookInstaller.hookCommand()])
        XCTAssertEqual(commands(forEvent: "PreToolUse", in: root), ["/usr/bin/true"])
    }

    func testInstallRefusesInvalidJSONAndLeavesFileUntouched() throws {
        let broken = "{ this is not json"
        try writeSettings(broken)

        XCTAssertThrowsError(try HookInstaller.install(port: 1, token: "t", settingsURL: settingsURL))
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), broken,
                       "an unparseable settings file must never be modified")
    }

    func testInstallUpgradesLegacyUnquotedRegistration() throws {
        // A legacy unquoted path (spaces in "Application Support") never
        // executed; install must replace it with the quoted form, once.
        let legacy = HookInstaller.hookScriptURL().path
        try writeSettings(#"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "\#(legacy)"}]}]}}
        """#)

        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)

        let root = try readSettingsObject()
        XCTAssertEqual(commands(forEvent: "Stop", in: root), [HookInstaller.hookCommand()])
    }

    func testInstallCreatesNumberedBackup() throws {
        try writeSettings(#"{"model": "opus"}"#)
        try HookInstaller.install(port: 1, token: "t", settingsURL: settingsURL)

        let backup = tempDir.appendingPathComponent("settings.json.powerup-backup-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"model": "opus"}"#)
    }

    // MARK: Install state

    func testInstallStateDetectsPortDrift() throws {
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)
        XCTAssertEqual(HookInstaller.installState(port: 48738, token: "tok", settingsURL: settingsURL), .installed)
        XCTAssertEqual(HookInstaller.installState(port: 50000, token: "tok", settingsURL: settingsURL), .outOfDate)
        XCTAssertEqual(HookInstaller.installState(port: 48738, token: "other", settingsURL: settingsURL), .outOfDate)
    }

    func testInstallStateOnEmptyFileIsNotInstalled() throws {
        XCTAssertEqual(HookInstaller.installState(port: 1, token: "t", settingsURL: settingsURL), .notInstalled)
        XCTAssertFalse(HookInstaller.isInstalled(settingsURL: settingsURL))
    }

    func testInstallFromOlderBuildMissingAnEventIsOutOfDate() throws {
        // An install written before SessionEnd joined hookEvents must report
        // out-of-date so Settings prompts a reinstall — a missing SessionEnd
        // is exactly the "light stuck on amber" bug.
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as? [String: Any])
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "SessionEnd")
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)

        XCTAssertEqual(HookInstaller.installState(port: 48738, token: "tok", settingsURL: settingsURL),
                       .outOfDate)

        // Reinstalling adds only the missing event back.
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)
        XCTAssertEqual(HookInstaller.installState(port: 48738, token: "tok", settingsURL: settingsURL),
                       .installed)
    }

    // MARK: Uninstall

    func testUninstallRemovesOnlyOursAndPrunesEmpties() throws {
        try writeSettings(#"""
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]}]
          }
        }
        """#)
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)
        try HookInstaller.uninstall(settingsURL: settingsURL)

        let root = try readSettingsObject()
        XCTAssertEqual(root["model"] as? String, "opus")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        // Our three events are pruned entirely; the foreign hook survives.
        XCTAssertNil(hooks["Stop"])
        XCTAssertNil(hooks["UserPromptSubmit"])
        XCTAssertNil(hooks["Notification"])
        XCTAssertEqual(commands(forEvent: "PreToolUse", in: root), ["/usr/bin/true"])
        XCTAssertFalse(HookInstaller.isInstalled(settingsURL: settingsURL))
    }

    func testUninstallRemovesHooksKeyWhenNothingRemains() throws {
        try HookInstaller.install(port: 48738, token: "tok", settingsURL: settingsURL)
        try HookInstaller.uninstall(settingsURL: settingsURL)

        let root = try readSettingsObject()
        XCTAssertNil(root["hooks"], "an empty hooks object should be pruned")
    }

    func testUninstallKeepsSharedGroupEntries() throws {
        // Our entry sharing a group with someone else's: only ours goes.
        try writeSettings(#"""
        {"hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": \#(quotedJSON(HookInstaller.hookCommand()))},
            {"type": "command", "command": "/usr/bin/true"}
        ]}]}}
        """#)
        try HookInstaller.uninstall(settingsURL: settingsURL)

        let root = try readSettingsObject()
        XCTAssertEqual(commands(forEvent: "Stop", in: root), ["/usr/bin/true"])
    }

    func testUninstallOnMissingFileIsANoOp() throws {
        XCTAssertNoThrow(try HookInstaller.uninstall(settingsURL: settingsURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    // MARK: Hook script

    func testHookScriptEscapesShellMetacharactersInToken() {
        let body = HookInstaller.hookScriptBody(port: 48738, token: #"a"b$c`d\e"#)
        XCTAssertTrue(body.contains(#"a\"b\$c\`d\\e"#), "token metacharacters must be escaped for bash: \(body)")
        XCTAssertTrue(body.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(body.contains("http://127.0.0.1:48738/event"))
        XCTAssertTrue(body.contains("exit 0"))
    }

    func testHookScriptClampsPortIntoValidRange() {
        XCTAssertTrue(HookInstaller.hookScriptBody(port: 999999, token: "t").contains("127.0.0.1:65535"))
        XCTAssertTrue(HookInstaller.hookScriptBody(port: -5, token: "t").contains("127.0.0.1:1/"))
    }

    func testHookCommandIsSingleQuoted() {
        let command = HookInstaller.hookCommand()
        XCTAssertTrue(command.hasPrefix("'") && command.hasSuffix("'"),
                      "the script path contains spaces and must be quoted: \(command)")
    }

    private func quotedJSON(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())   // strip the [ ] around the encoded string
    }
}
