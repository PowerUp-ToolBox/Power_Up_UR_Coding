import Foundation
import CryptoKit

/// Persists the transcript per project as JSON Lines under
/// `~/Library/Application Support/PowerUp/transcripts/`, so relaunching
/// PowerUp (which resumes the Claude session with `--resume`) also restores
/// the conversation you're resuming.
///
/// Persistence is a convenience, never a dependency: every failure here is
/// swallowed — a full disk or an unreadable file costs the user their
/// scrollback, not their session. Corrupt or unknown lines are skipped on
/// load, and an overgrown file is compacted down to its newest entries.
@MainActor
final class TranscriptStore {

    /// Test seam — mirrors `HookInstaller.supportDirectoryOverride`, so tests
    /// exercise real files in a temp directory without ever touching a live
    /// installation's history.
    static var supportDirectoryOverride: URL?

    /// A file that has grown past this many entries is rewritten with only the
    /// newest `maxStoredEntries` when it is next loaded.
    static let maxStoredEntries = 2000

    /// How many entries a restore brings back by default — enough scrollback
    /// to re-read the recent conversation without flooding the window.
    static let defaultRestoreCount = 200

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
    /// collide and renaming nothing keeps history attached.
    static func fileURL(forProjectDir path: String) -> URL {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()

        let basename = URL(fileURLWithPath: standardized, isDirectory: true).lastPathComponent
        let slugCharacters = basename.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "-"
        }
        let slug = String(slugCharacters)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(40)

        let name = slug.isEmpty ? hash : "\(slug)-\(hash)"
        return transcriptsDirectory.appendingPathComponent(name + ".jsonl")
    }

    /// Switches which project's file `append` writes to. Passing nil (no
    /// project chosen) turns persistence off.
    func setProject(_ path: String?) {
        projectDir = (path?.isEmpty == true) ? nil : path
    }

    /// Appends one entry to the active project's file. No project → no-op.
    func append(_ entry: TranscriptEntry) {
        guard let projectDir else { return }
        guard var line = try? TranscriptStore.encoder.encode(entry) else { return }
        line.append(0x0A)

        let url = TranscriptStore.fileURL(forProjectDir: projectDir)
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
    /// `maxStoredEntries`.
    func loadTail(maxEntries: Int = TranscriptStore.defaultRestoreCount) -> [TranscriptEntry] {
        guard let projectDir, maxEntries > 0 else { return [] }
        let url = TranscriptStore.fileURL(forProjectDir: projectDir)
        guard let data = try? Data(contentsOf: url) else { return [] }

        var entries: [TranscriptEntry] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = try? TranscriptStore.decoder.decode(TranscriptEntry.self, from: Data(line)) else {
                continue
            }
            entries.append(entry)
        }

        if entries.count > TranscriptStore.maxStoredEntries {
            entries = Array(entries.suffix(TranscriptStore.maxStoredEntries))
            rewrite(entries, to: url)
        }

        return Array(entries.suffix(maxEntries))
    }

    private func rewrite(_ entries: [TranscriptEntry], to url: URL) {
        var data = Data()
        for entry in entries {
            guard var line = try? TranscriptStore.encoder.encode(entry) else { continue }
            line.append(0x0A)
            data.append(line)
        }
        try? data.write(to: url, options: .atomic)
    }

    // Compact single-line JSON per entry; dates as epoch seconds so the format
    // is trivially greppable and stable across builds.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
