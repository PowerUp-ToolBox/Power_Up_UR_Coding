import Foundation
@testable import PowerUp

/// A hermetic sandbox for constructing `AppState` through its test seam
/// (`AppState(configStore:…, sideEffects: [])`).
///
/// Everything AppState would read or write on disk is pointed at one temp
/// directory: the config file (injected `ConfigStore(fileURL:)`), the
/// per-project transcripts and the hook script (the support-directory
/// overrides) and `~/.claude/settings.json` (`HookInstaller.settingsURLOverride`),
/// so AppState's hook install/uninstall edits a throwaway copy. No controller, audio device listener, loopback port, keyboard
/// monitor, terminate observer or cmux probe is started, so a test needs no
/// hardware, prompts nobody and binds nothing.
///
/// Usage (from a `@MainActor` XCTestCase):
///
///     env = try AppStateTestEnvironment()        // setUp
///     let app = env.makeAppState()
///     ...
///     env.tearDown()                              // tearDown
@MainActor
final class AppStateTestEnvironment {

    /// Root of everything this environment writes.
    let directory: URL
    /// Where the injected config store reads and writes `config.json`.
    let configURL: URL
    /// Stands in for `~/Library/Application Support/PowerUp/`: transcripts
    /// and the hook script are written under it.
    let supportDirectory: URL
    /// Stands in for `~/.claude/settings.json` (where the remote-control
    /// hooks are registered).
    let settingsURL: URL

    /// - Parameter config: written to the sandboxed `config.json` before any
    ///   store reads it; nil starts from no file at all (first launch).
    init(config: AppConfig? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-appstate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.json")

        supportDirectory = directory.appendingPathComponent("support", isDirectory: true)
        settingsURL = directory.appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        TranscriptStore.supportDirectoryOverride = supportDirectory
        HookInstaller.supportDirectoryOverride = supportDirectory
        HookInstaller.settingsURLOverride = settingsURL

        if let config {
            try ConfigStore.encode(config).write(to: configURL, options: .atomic)
        }
    }

    /// A config store reading and writing only the sandboxed config file.
    func makeConfigStore() -> ConfigStore {
        ConfigStore(fileURL: configURL)
    }

    /// AppState wired to real but unstarted services (pass your own to keep a
    /// handle on one), with every start-up side effect skipped. Pass a
    /// `FakeHarnessAdapter` as `harness` to script the session, and
    /// `SpeechService(engine: ScriptedSpeechEngine())` as `speech` to script
    /// what the microphone "hears".
    func makeAppState(configStore: ConfigStore? = nil,
                      controller: ControllerService? = nil,
                      speech: SpeechService? = nil,
                      tts: TTSService? = nil,
                      claude: ClaudeService? = nil,
                      harness: (any HarnessAdapter)? = nil,
                      remote: RemoteControlService? = nil,
                      listener: RemoteListener? = nil,
                      audioDevices: AudioDeviceStore? = nil,
                      transcriptStore: TranscriptStore? = nil) -> AppState {
        AppState(configStore: configStore ?? makeConfigStore(),
                 controller: controller,
                 speech: speech,
                 tts: tts,
                 claude: claude,
                 harness: harness,
                 remote: remote,
                 listener: listener,
                 audioDevices: audioDevices,
                 transcriptStore: transcriptStore,
                 sideEffects: [])
    }

    /// Parks the storage overrides in `TestSandbox.quarantine` (never back on
    /// the real folders) and deletes the sandbox.
    func tearDown() {
        TestSandbox.parkOverrides()
        try? FileManager.default.removeItem(at: directory)
    }
}
