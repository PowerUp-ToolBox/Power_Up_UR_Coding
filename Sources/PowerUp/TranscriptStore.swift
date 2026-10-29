import Foundation

/// Persists the transcript per project as JSON Lines under
/// `~/Library/Application Support/PowerUp/transcripts/`, so relaunching
/// PowerUp (which resumes the Claude session with `--resume`) also restores
/// the conversation you're resuming.
///
/// Persistence is a convenience, never a dependency: every failure here is
/// swallowed — a full disk or an unreadable file costs the user their
/// scrollback, not their session. Corrupt or unknown lines are skipped on
/// load, and an overgrown file is compacted down to its newest entries.
///
/// The line format, the load rules and the file name are the Rust core's
/// (DESIGN v2.14, `CoreBridgeTranscript.swift`); this class keeps the
/// folder, the append, the atomic rewrite and the standardized path.
@MainActor
final class TranscriptStore {

    /// Test seam — mirrors `HookInstaller.supportDirectoryOverride`, so tests
    /// exercise real files in a temp directory without ever touching a live
    /// installation's history.
    static var supportDirectoryOverride: URL?

    /// A file that has grown past this many entries is rewritten with only the
    /// newest `maxStoredEntries` when it is next loaded (the core's limit).
    static let maxStoredEntries = CoreBridge.transcriptLimits.maxStored

    /// How many entries a restore brings back by default — enough scrollback
    /// to re-read the recent conversation without flooding the window.
    static let defaultRestoreCount = CoreBridge.transcriptLimits.restoreCount

    /// The project the store currently appends for; nil = nothing persisted.
    private(set) var projectDir: String?

    static var transcriptsDirectory: URL {
        if let supportDirectoryOverride {
            return supportDirectoryOverride.appendingPathComponent("transcripts", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PowerUp", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
    }

    /// One stable file per project: a readable slug from the folder name plus
    /// a hash of the full standardized path, so `~/a/api` and `~/b/api` never
    /// collide and renaming nothing keeps history attached. The core names
    /// the file; standardizing the path is the platform's rule (on macOS it
    /// also decomposes accents). Nil only when the core fails, and then
    /// nothing is persisted.
    static func fileURL(forProjectDir path: String) -> URL? {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard let name = CoreBridge.transcriptFileName(standardizedPath: standardized) else { return nil }
        return transcriptsDirectory.appendingPathComponent(name)
    }

    /// Switches which project's file `append` writes to. Passing nil (no
    /// project chosen) turns persistence off.
    func setProject(_ path: String?) {
        projectDir = (path?.isEmpty == true) ? nil : path
    }

    /// Appends one entry to the active project's file. No project → no-op.
    func append(_ entry: TranscriptEntry) {
        guard let projectDir,
              let line = CoreBridge.transcriptLine(entry),
              let url = TranscriptStore.fileURL(forProjectDir: projectDir) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.fileExists(atPath: url.path) else {
                try line.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // History is best-effort; never let persistence break the session.
        }
    }

    /// The newest `maxEntries` entries of the active project's history, oldest
    /// first. Lines that don't decode (corrupt, or written by a future build)
    /// are skipped. Loading also compacts a file that outgrew
    /// `maxStoredEntries`, writing the core's bytes atomically.
    func loadTail(maxEntries: Int = TranscriptStore.defaultRestoreCount) -> [TranscriptEntry] {
        guard let projectDir, maxEntries > 0,
              let url = TranscriptStore.fileURL(forProjectDir: projectDir),
              let data = try? Data(contentsOf: url),
              let load = CoreBridge.transcriptLoad(data, maxEntries: maxEntries) else { return [] }
        if let rewrite = load.rewrite {
            try? rewrite.write(to: url, options: .atomic)
        }
        return load.entries
    }
}
