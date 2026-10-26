import XCTest
@testable import PowerUp

/// Proves the test suite never reads or writes the person's real PowerUp data
/// (#114): the config file, the Application Support folder (transcripts, hook
/// script) and `~/.claude/settings.json`. Every persistent path AppState can
/// reach is resolved through a test seam — `ConfigStore(fileURL:)`,
/// `TranscriptStore.supportDirectoryOverride`,
/// `HookInstaller.supportDirectoryOverride` and
/// `HookInstaller.settingsURLOverride` — and `AppStateTestEnvironment` points
/// all of them into one temp directory. Writing scenarios check that the files
/// land there; a source scan keeps future suites from bypassing the seams.
@MainActor
final class HermeticStorageTests: XCTestCase {

    private var env: AppStateTestEnvironment!

    override func setUpWithError() throws {
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
    }

    // MARK: Every persistent path resolves into the sandbox

    func testEnvironmentPointsEveryPersistentPathIntoItsSandbox() {
        let resolved: [(String, URL)] = [
            ("config file", env.makeConfigStore().fileURL),
            ("transcripts directory", TranscriptStore.transcriptsDirectory),
            ("transcript file", TranscriptStore.fileURL(forProjectDir: "/tmp/powerup-hermetic-project")),
            ("support directory", HookInstaller.supportDirectory),
            ("hook script", HookInstaller.hookScriptURL()),
            ("Claude settings file", HookInstaller.defaultSettingsURL),
        ]
        for (name, url) in resolved {
            XCTAssertTrue(Self.isInside(url, env.directory),
                          "\(name) resolves to \(url.path), outside the test sandbox \(env.directory.path)")
        }
        XCTAssertEqual(HookInstaller.defaultSettingsURL, env.settingsURL)
    }

    func testAppStateUsesTheSandboxedConfigFile() {
        let app = env.makeAppState()

        XCTAssertEqual(app.configStore.fileURL, env.configURL)
    }

    // MARK: Writes through AppState land in the sandbox

    func testInstallingRemoteHooksWritesOnlyTheSandboxedSettingsAndScript() throws {
        // Refuse to go on if the seam is missing: the install below would
        // otherwise edit the real ~/.claude/settings.json.
        guard HookInstaller.defaultSettingsURL == env.settingsURL,
              HookInstaller.supportDirectory == env.supportDirectory else {
            return XCTFail("HookInstaller is not pointed at the sandbox; not installing")
        }
        let app = env.makeAppState()

        XCTAssertNil(app.installRemoteHooks())

        let settings = try String(contentsOf: env.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("powerup-hook.sh"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: env.supportDirectory.appendingPathComponent("powerup-hook.sh").path))
        XCTAssertTrue(HookInstaller.isInstalled())
        XCTAssertEqual(app.transcript.last?.text,
                       "Claude Code hooks installed — replies from any terminal session will be read back.")
    }

    func testUninstallingRemoteHooksEditsOnlyTheSandboxedSettings() throws {
        guard HookInstaller.defaultSettingsURL == env.settingsURL else {
            return XCTFail("HookInstaller is not pointed at the sandbox; not uninstalling")
        }
        let app = env.makeAppState()
        XCTAssertNil(app.installRemoteHooks())

        XCTAssertNil(app.uninstallRemoteHooks())

        XCTAssertFalse(HookInstaller.isInstalled())
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.settingsURL.path))
        XCTAssertEqual(app.transcript.last?.text, "Claude Code hooks removed.")
    }

    func testTranscriptEntriesPersistIntoTheSandbox() throws {
        env.tearDown()
        let project = env.directory.appendingPathComponent("project", isDirectory: true).path
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false
        config.projectDir = project
        env = try AppStateTestEnvironment(config: config)
        let controller = ControllerService()
        let app = env.makeAppState(controller: controller)

        controller.onLowBattery?(0.15)

        let file = TranscriptStore.fileURL(forProjectDir: project)
        XCTAssertTrue(Self.isInside(file, env.directory))
        let persisted = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(persisted.contains("Controller battery is low (15%)"))
        withExtendedLifetime(app) {}
    }

    func testConfigSavesGoToTheSandboxedFile() throws {
        let app = env.makeAppState()

        app.configStore.config.listenerPort = 50123
        app.configStore.save()

        let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: env.configURL))
        XCTAssertEqual(onDisk.listenerPort, 50123)
    }

    // MARK: After a test the seams stay parked away from the real folders

    func testTearDownParksTheOverridesInTheQuarantineInsteadOfTheRealFolders() throws {
        env.tearDown()

        let quarantine = TestSandbox.quarantine
        XCTAssertTrue(Self.isInside(TranscriptStore.transcriptsDirectory, quarantine))
        XCTAssertEqual(HookInstaller.supportDirectory, quarantine)
        XCTAssertTrue(Self.isInside(HookInstaller.defaultSettingsURL, quarantine))

        env = try AppStateTestEnvironment()
    }

    // MARK: No suite bypasses the seams

    /// A source scan of the test target: the constructions below resolve the
    /// real configuration, support folder or Claude settings file, or type
    /// into the person's real terminal, so a test that uses them would touch
    /// the person's own data. Use `AppStateTestEnvironment` (or pass
    /// `settingsURL:` / set the overrides, or inject a `RecordingInjector`)
    /// and park the overrides with `TestSandbox` in tearDown instead.
    func testNoTestSourceBypassesTheStorageSeams() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let thisFile = URL(fileURLWithPath: #filePath).lastPathComponent
        let sources = try FileManager.default.contentsOfDirectory(at: testsDirectory,
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != thisFile }
        XCTAssertFalse(sources.isEmpty, "found no test sources next to \(thisFile)")

        // Each entry: a construction that reaches real storage, and why. A
        // name only matches on its own (`makeConfigStore()` is fine).
        let forbidden: [(name: String, why: String)] = [
            ("ConfigStore()", "the production config store reads and writes the real config.json"),
            ("ConfigStore.configURL", "that is the real config.json"),
            ("AppState()", "the production initializer uses the real config and starts every side effect"),
            ("HookInstaller.defaultSettingsURL", "that is the real ~/.claude/settings.json unless the override is set"),
            ("supportDirectoryOverride = nil", "park the override with TestSandbox instead of reverting to the real folder"),
            ("settingsURLOverride = nil", "park the override with TestSandbox instead of reverting to the real file"),
            ("RemoteControlService()", "the production remote service types into the real terminal (cmux or the "
                + "frontmost app); pass RemoteControlService(injector: RecordingInjector())"),
        ]
        // HookInstaller entry points whose settings path defaults to the real
        // file: in a test they must name `settingsURL:` explicitly.
        let settingsEntryPoints = ["HookInstaller.install(", "HookInstaller.uninstall(",
                                   "HookInstaller.isInstalled(", "HookInstaller.installState("]

        var violations: [String] = []
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                let location = "\(file.lastPathComponent):\(index + 1)"
                for rule in forbidden where Self.contains(code, standalone: rule.name) {
                    violations.append("\(location) uses \(rule.name) — \(rule.why)")
                }
                for entry in settingsEntryPoints
                where Self.contains(code, standalone: entry) && !code.contains("settingsURL:") {
                    violations.append("\(location) calls \(entry)…) without settingsURL: — it would use the real settings file")
                }
            }
        }
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    /// True when `url` lies strictly below `directory`.
    private static func isInside(_ url: URL, _ directory: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// True when `name` occurs in `code` not preceded by an identifier
    /// character, so `makeAppState()` does not count as `AppState()`.
    private static func contains(_ code: String, standalone name: String) -> Bool {
        var searchStart = code.startIndex
        while let range = code.range(of: name, range: searchStart..<code.endIndex) {
            if range.lowerBound == code.startIndex { return true }
            let before = code[code.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
