import Foundation
import PowerUpCore

/// The transcript's JSON Lines rules (slice 2.5, DESIGN v2.14): the core
/// owns the line an entry is written as, how a file's bytes load and what
/// each project's file is called; TranscriptStore keeps the folder, the
/// append, the atomic rewrite and the standardized project path.
extension CoreBridge {
    /// What loading a transcript file's bytes found.
    struct TranscriptLoad: Equatable {
        /// The newest entries asked for, oldest first.
        let entries: [TranscriptEntry]
        /// The bytes to replace the file with when it outgrew
        /// `maxStoredEntries`; nil when it stays as it is.
        let rewrite: Data?
    }

    /// The bytes one entry appends to its file, LF included; nil when the
    /// core fails.
    static func transcriptLine(_ entry: TranscriptEntry) -> Data? {
        call("transcriptLine", fallback: nil) {
            try PowerUpCore.transcriptLine(entry: entry.core)
        }
    }

    /// A transcript file's bytes loaded; nil when the core fails, which the
    /// caller treats as no history (never as a file to rewrite).
    static func transcriptLoad(_ data: Data, maxEntries: Int) -> TranscriptLoad? {
        call("transcriptLoad", fallback: nil) {
            let load = try PowerUpCore.transcriptLoad(bytes: data,
                                                      maxEntries: UInt32(clamping: max(0, maxEntries)))
            return TranscriptLoad(entries: load.entries.compactMap { TranscriptEntry($0) },
                                  rewrite: load.rewrite)
        }
    }

    /// The transcript file name for a standardized project path; nil when
    /// the core fails.
    static func transcriptFileName(standardizedPath: String) -> String? {
        call("transcriptFileName", fallback: nil) {
            try PowerUpCore.transcriptFileName(standardizedPath: standardizedPath)
        }
    }

    /// How many entries a file keeps and a restore brings back. The literals
    /// are only the fallback for a failed core call, pinned equal to the
    /// core's by a test.
    static var transcriptLimits: (maxStored: Int, restoreCount: Int) {
        call("transcriptLimits", fallback: (maxStored: 2000, restoreCount: 200)) {
            let limits = try PowerUpCore.transcriptLimits()
            return (maxStored: Int(limits.maxStoredEntries), restoreCount: Int(limits.defaultRestoreCount))
        }
    }
}

// MARK: - Conversions

extension TranscriptEntry.Kind {
    var core: CoreTranscriptKind {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        case .system: return .system
        case .error: return .error
        }
    }
}

fileprivate extension TranscriptEntry {
    /// The entry the core read; nil only for an id the core would never
    /// return (it hands back `uuidString`s).
    init?(_ core: CoreTranscriptEntry) {
        guard let id = UUID(uuidString: core.id) else { return nil }
        self.init(id: id, kind: Kind(core.kind), text: core.text,
                  date: Date(timeIntervalSince1970: core.dateSeconds))
    }

    var core: CoreTranscriptEntry {
        CoreTranscriptEntry(id: id.uuidString, kind: kind.core, text: text,
                            dateSeconds: date.timeIntervalSince1970)
    }
}
