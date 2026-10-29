import os
import PowerUpCore

/// The Rust core's bridge as the app sees it (ADR 0012). The app checks once
/// at launch that the core answers, and logs the result — the evidence the
/// stage 2 kill rule asks for: the bridge running inside the signed bundle.
enum CoreBridge {
    /// The launch check's outcome, as logged.
    enum Status: Equatable {
        case answering
        case failed(String)
    }

    static func check() -> Status {
        do {
            return try probeEcho(text: "ping") == "ping" ? .answering : .failed("echo mismatch")
        } catch {
            return .failed("\(error)")
        }
    }

    /// Logs the launch check under the app's subsystem, category `core`.
    static func logStatus() {
        let log = Logger(subsystem: "com.powerup.claudepad", category: "core")
        switch check() {
        case .answering: log.notice("Rust core linked and answering")
        case .failed(let reason): log.error("Rust core linked but failed: \(reason, privacy: .public)")
        }
    }
}
