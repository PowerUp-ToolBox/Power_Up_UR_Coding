import Foundation
@testable import PowerUp

/// The process-wide parking spot for the storage overrides between tests.
///
/// Suites point `TranscriptStore` and `HookInstaller` at their own temp
/// directory while a test runs. When the test ends they park the overrides
/// here instead of resetting them to nil: a write that lands after a test (a
/// debounced config save, a late Task appending to the transcript of an
/// AppState that has not been released yet) then goes to this throwaway
/// folder and never reaches the real Application Support folder or
/// `~/.claude/settings.json`. `HermeticStorageTests` scans the test sources for
/// `= nil` resets and fails if one comes back.
enum TestSandbox {

    /// One throwaway directory per test process.
    static let quarantine: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("powerup-tests-quarantine-\(UUID().uuidString)", isDirectory: true)

    /// Parks every storage override (transcripts, hook script, Claude settings
    /// file) in the quarantine.
    @MainActor
    static func parkOverrides() {
        TranscriptStore.supportDirectoryOverride = quarantine
        parkHookInstallerOverrides()
    }

    /// The `HookInstaller` half of `parkOverrides()`, callable from suites that
    /// do not run on the main actor.
    static func parkHookInstallerOverrides() {
        HookInstaller.supportDirectoryOverride = quarantine
        HookInstaller.settingsURLOverride = quarantine.appendingPathComponent("settings.json")
    }
}
