import os
#if POWERUP_CORE
import PowerUpCore
#endif

/// The Rust core's bridge as the app sees it (stage 2.1, ADR 0012). Until
/// slice 2.2 moves real logic across, the app only checks once at launch that
/// the core is linked and answers, and logs the result — the evidence the
/// stage 2 kill rule asks for: the bridge running inside the signed bundle.
enum CoreBridge {
    /// The launch check's outcome, as logged.
    enum Status: Equatable {
        case notLinked
        case answering
        case failed(String)
    }

    static func check() -> Status {
        #if POWERUP_CORE
        do {
            return try probeEcho(text: "ping") == "ping" ? .answering : .failed("echo mismatch")
        } catch {
            return .failed("\(error)")
        }
        #else
        return .notLinked
        #endif
    }

    /// Logs the launch check under the app's subsystem, category `core`.
    static func logStatus() {
        let log = Logger(subsystem: "com.powerup.claudepad", category: "core")
        switch check() {
        case .notLinked: log.notice("Rust core not linked (built without scripts/build-core.sh)")
        case .answering: log.notice("Rust core linked and answering")
        case .failed(let reason): log.error("Rust core linked but failed: \(reason, privacy: .public)")
        }
    }
}
