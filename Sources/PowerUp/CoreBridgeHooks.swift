import Foundation
import PowerUpCore

/// The Claude Code hooks (slice 2.5, DESIGN v2.14): the core owns the
/// command registered, the hook script's text, what installing or removing
/// the hooks does to `~/.claude/settings.json` and whether they are
/// installed; HookInstaller keeps the paths and their test seams, reading
/// and writing both files, the numbered backup and the settings writer.
extension CoreBridge {
    /// Why an edit left the settings file alone.
    enum SettingsRefusal: Equatable {
        /// The file is not a JSON object.
        case invalidJSON
        /// `hooks` is there and is not an object.
        case hooksNotAnObject
        /// The named event is there and is not an array.
        case eventNotAnArray(String)
    }

    /// What an install or uninstall does to the settings file.
    enum SettingsEdit: Equatable {
        /// Nothing changes: no write, no backup.
        case unchanged
        /// The whole new file as compact UTF-8 JSON, every number spelled
        /// as the file spelled it, for `HookInstaller`'s writer to format.
        case write(Data)
        case refused(SettingsRefusal)
    }

    /// The hook events PowerUp registers, in their stable order; empty when
    /// the core fails (nothing in the app registers from this list: the
    /// core's edits do).
    static var hookEvents: [String] {
        call("hookEvents", fallback: []) { try PowerUpCore.hookEvents() }
    }

    /// The command registered for the hook script; nil when the core fails.
    static func hookCommand(scriptPath: String) -> String? {
        call("hookCommand", fallback: nil) { try PowerUpCore.hookCommand(scriptPath: scriptPath) }
    }

    /// The hook script's text; nil when the core fails, and then no script
    /// is written.
    static func hookScriptBody(port: Int, token: String) -> String? {
        call("hookScriptBody", fallback: nil) {
            try PowerUpCore.hookScriptBody(port: Int64(port), token: token)
        }
    }

    /// Whether the Stop hook points at the script (`settings` nil: no
    /// file); false when the core fails.
    static func hooksInstalled(settings: Data?, scriptPath: String) -> Bool {
        call("hooksInstalled", fallback: false) {
            try PowerUpCore.hooksInstalled(settings: settings, scriptPath: scriptPath)
        }
    }

    /// The full install state (`scriptOnDisk` nil: no script);
    /// notInstalled when the core fails, so Settings offers an install.
    static func hookInstallState(settings: Data?, scriptPath: String, scriptOnDisk: Data?,
                                 port: Int, token: String) -> HookInstaller.InstallState {
        call("hookInstallState", fallback: .notInstalled) {
            HookInstaller.InstallState(try PowerUpCore.hookInstallState(
                settings: settings, scriptPath: scriptPath, scriptOnDisk: scriptOnDisk,
                port: Int64(port), token: token))
        }
    }

    /// What installing the hooks does to the settings file; nil when the
    /// core fails, which the caller treats as a file it must leave alone.
    static func hookInstallEdit(settings: Data?, scriptPath: String) -> SettingsEdit? {
        call("hookInstallEdit", fallback: nil) {
            SettingsEdit(try PowerUpCore.hookInstallEdit(settings: settings, scriptPath: scriptPath))
        }
    }

    /// What removing the hooks does to the settings file; nil when the core
    /// fails, as `hookInstallEdit`.
    static func hookUninstallEdit(settings: Data?, scriptPath: String) -> SettingsEdit? {
        call("hookUninstallEdit", fallback: nil) {
            SettingsEdit(try PowerUpCore.hookUninstallEdit(settings: settings, scriptPath: scriptPath))
        }
    }
}

// MARK: - Conversions

fileprivate extension HookInstaller.InstallState {
    init(_ core: CoreHookInstallState) {
        switch core {
        case .notInstalled: self = .notInstalled
        case .installed: self = .installed
        case .outOfDate: self = .outOfDate
        }
    }
}

fileprivate extension CoreBridge.SettingsEdit {
    init(_ core: CoreSettingsEdit) {
        switch core {
        case .unchanged: self = .unchanged
        case .write(let json): self = .write(json)
        case .refused(let refusal): self = .refused(CoreBridge.SettingsRefusal(refusal))
        }
    }
}

fileprivate extension CoreBridge.SettingsRefusal {
    init(_ core: CoreSettingsRefusal) {
        switch core {
        case .invalidJson: self = .invalidJSON
        case .hooksNotAnObject: self = .hooksNotAnObject
        case .eventNotAnArray(let event): self = .eventNotAnArray(event)
        }
    }
}
