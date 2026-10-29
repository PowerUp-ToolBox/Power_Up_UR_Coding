import Foundation

/// Installs (and removes) the Claude Code hooks that give PowerUp voice
/// read-back from *any* claude session on this machine — terminal, cmux, or
/// PowerUp's own.
///
/// Hooks live in `~/.claude/settings.json`, a file the user owns and that other
/// tools also write to, so every edit is conservative: unknown keys are
/// copied through verbatim, a numbered backup is taken before writing, and a
/// settings file that isn't valid JSON is left completely untouched.
///
/// The rules live in the Rust core since slice 2.5 (DESIGN v2.14): what an
/// install or uninstall does to the file, the command registered, the
/// script's text and the install state. This type keeps the files: the
/// paths and their test seams, reading the settings and the script, the
/// numbered backup, the settings writer and the script's atomic, executable
/// write.
///
/// The settings path is injectable so the merge logic can be exercised against a
/// throwaway copy without going anywhere near the real file.
enum HookInstaller {

    /// Hook events PowerUp subscribes to, in a stable order (the core's
    /// list). SessionEnd is how a session that closes MID-TURN releases the
    /// "Claude is working" state — its Stop hook never fires, and without
    /// SessionEnd the light bar would stay amber forever. PostToolUse is the
    /// turn HEARTBEAT: it fires on every tool call, keeping long working
    /// turns visibly alive.
    static var hookEvents: [String] { CoreBridge.hookEvents }

    // MARK: - Errors

    enum HookError: LocalizedError {
        case invalidSettings(String)
        case unexpectedShape(String)
        case fileError(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let path):
                return "\(path) isn't valid JSON, so PowerUp didn't touch it. Fix or move the file, then try again."
            case .unexpectedShape(let detail):
                return detail
            case .fileError(let detail):
                return detail
            }
        }
    }

    // MARK: - Paths

    /// Test seam: when set, the hook script is written under this directory
    /// instead of the real Application Support one, so tests can exercise
    /// install/uninstall without touching a live PowerUp installation.
    static var supportDirectoryOverride: URL?

    /// `~/Library/Application Support/PowerUp/` (falls back to a temp dir if the
    /// Application Support directory can't be located).
    static var supportDirectory: URL {
        if let supportDirectoryOverride { return supportDirectoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (base ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PowerUp", isDirectory: true)
    }

    static func hookScriptURL() -> URL {
        supportDirectory.appendingPathComponent("powerup-hook.sh")
    }

    /// The command string registered in settings.json. Claude Code runs a hook's
    /// `command` through a shell, and our script lives under "Application
    /// Support" — an unquoted path with spaces would split into a nonexistent
    /// command (`…/Application` — exit 127) and every hook would silently die.
    /// The core single-quotes the path; nil only when the core fails.
    static func hookCommand() -> String? {
        CoreBridge.hookCommand(scriptPath: hookScriptURL().path)
    }

    /// Test seam, beside `supportDirectoryOverride`: when set, every call that
    /// does not pass its own `settingsURL` (AppState's install, uninstall and
    /// hook-script refresh) uses this file instead of the real one, so a test
    /// driving AppState never edits `~/.claude/settings.json`.
    static var settingsURLOverride: URL?

    /// The real `~/.claude/settings.json` (or `settingsURLOverride` in tests).
    static var defaultSettingsURL: URL {
        if let settingsURLOverride { return settingsURLOverride }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    // MARK: - Hook script

    /// Writes (or rewrites) the executable hook script for the given port/token.
    ///
    /// The script must never slow Claude down: it reads the event payload from
    /// stdin *first* (`payload=$(cat)`), then fires curl in the background and
    /// exits 0 immediately — so PowerUp being closed, the port being wrong, or
    /// the listener being wedged costs the session nothing.
    static func writeHookScript(port: Int, token: String) throws {
        let url = hookScriptURL()
        let directory = url.deletingLastPathComponent()
        // A core failure must never install an empty script: it would
        // silently swallow every hook.
        guard let body = hookScriptBody(port: port, token: token) else {
            throw HookError.fileError("PowerUp couldn't prepare the hook script, so it didn't write \(url.path).")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: url.path)
        } catch {
            throw HookError.fileError("Couldn't write the hook script to \(url.path): \(error.localizedDescription)")
        }
    }

    /// The script for a port and token, from the core: the port clamped to
    /// 1...65535, the token escaped for a double-quoted bash string. Nil
    /// only when the core fails.
    static func hookScriptBody(port: Int, token: String) -> String? {
        CoreBridge.hookScriptBody(port: port, token: token)
    }

    // MARK: - Status

    /// How the registered hooks relate to the port/token PowerUp is using now.
    enum InstallState: Equatable {
        case notInstalled
        /// Registered and the script carries the current port and token.
        case installed
        /// Registered, but stale: the script was written for a different
        /// port/token (or is missing), or the registration is a legacy unquoted
        /// path that the shell can't execute. Reinstalling fixes it.
        case outOfDate
    }

    /// True when the Stop hook in the settings file points at our script
    /// (either the shell-safe quoted form or a legacy unquoted registration).
    static func isInstalled(settingsURL: URL = HookInstaller.defaultSettingsURL) -> Bool {
        let settings: Data?
        do {
            settings = try settingsData(at: settingsURL)
        } catch {
            return false
        }
        return CoreBridge.hooksInstalled(settings: settings, scriptPath: hookScriptURL().path)
    }

    /// Full status for the Settings UI: not just "is the path registered", but
    /// "will the hooks actually reach the listener as configured right now".
    /// The registration alone can look fine while the script still posts to a
    /// port the listener left long ago — that drift is exactly what this catches.
    static func installState(port: Int,
                             token: String,
                             settingsURL: URL = HookInstaller.defaultSettingsURL) -> InstallState {
        let settings: Data?
        do {
            settings = try settingsData(at: settingsURL)
        } catch {
            return .notInstalled
        }
        return CoreBridge.hookInstallState(settings: settings,
                                           scriptPath: hookScriptURL().path,
                                           scriptOnDisk: try? Data(contentsOf: hookScriptURL()),
                                           port: port,
                                           token: token)
    }

    // MARK: - Install / uninstall

    /// Rewrites the hook script and merges our entries into the settings file.
    /// Idempotent: running it twice leaves exactly one entry per event.
    static func install(port: Int,
                        token: String,
                        settingsURL: URL = HookInstaller.defaultSettingsURL) throws {
        try writeHookScript(port: port, token: token)
        let settings = try settingsData(at: settingsURL)
        try apply(CoreBridge.hookInstallEdit(settings: settings, scriptPath: hookScriptURL().path),
                  to: settingsURL)
    }

    /// Removes only the entries whose command is our script, pruning any group,
    /// event array, or `hooks` object left empty by the removal.
    static func uninstall(settingsURL: URL = HookInstaller.defaultSettingsURL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let settings = try settingsData(at: settingsURL)
        try apply(CoreBridge.hookUninstallEdit(settings: settings, scriptPath: hookScriptURL().path),
                  to: settingsURL)
    }

    /// Carries out the core's decision: nothing, the new file, or the error
    /// that tells the person why their file was left alone. A failed core
    /// call leaves the file alone too.
    private static func apply(_ edit: CoreBridge.SettingsEdit?, to url: URL) throws {
        switch edit {
        case .unchanged?:
            return
        case .write(let json)?:
            try writeSettings(json, to: url)
        case .refused(.invalidJSON)?:
            throw HookError.invalidSettings(url.path)
        case .refused(.hooksNotAnObject)?:
            throw HookError.unexpectedShape(
                "The \"hooks\" section of \(url.path) isn't in the expected format, so PowerUp left it alone.")
        case .refused(.eventNotAnArray(let event))?:
            throw HookError.unexpectedShape(
                "The \"\(event)\" hooks in \(url.path) aren't in the expected format, so PowerUp left them alone.")
        case nil:
            throw HookError.unexpectedShape("PowerUp couldn't rewrite \(url.path) safely, so it left it alone.")
        }
    }

    // MARK: - Settings file I/O

    /// The settings file's bytes, or nil when there is no file (the core
    /// starts from `{}` then, as it does for a blank file).
    private static func settingsData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw HookError.fileError("Couldn't read \(url.path): \(error.localizedDescription)")
        }
    }

    /// The bytes written for the core's merged file: Foundation reads the
    /// core's compact JSON back (every number literal as the person's file
    /// spelled it, so it reads the same NSNumber it read before) and writes
    /// it with sorted keys, slashes unescaped and pretty printing, plus a
    /// trailing newline like every other editor writes. Foundation's
    /// collation orders the keys, which the core leaves to it (HK-417).
    ///
    /// Throws `invalidSettings` when Foundation cannot read the JSON back:
    /// the core read a number Foundation refuses (one with more than 17
    /// digits whose exponent Decimal cannot hold), so the file stays as it
    /// is, as it did before the core.
    static func settingsBytes(fromCoreJSON json: Data, path: String) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: json, options: []) else {
            throw HookError.invalidSettings(path)
        }
        guard JSONSerialization.isValidJSONObject(root),
              var data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            throw HookError.unexpectedShape("PowerUp couldn't rewrite \(path) safely, so it left it alone.")
        }
        data.append(0x0A)
        return data
    }

    /// Backs the current file up, then writes the merged file atomically.
    private static func writeSettings(_ json: Data, to url: URL) throws {
        let data = try settingsBytes(fromCoreJSON: json, path: url.path)

        backUp(url)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw HookError.fileError("Couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Copies the current settings file to `settings.json.powerup-backup-N`,
    /// picking the lowest free N. Best effort — a failed backup never blocks the
    /// (already validated) write.
    private static func backUp(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for counter in 1...999 {
            let candidate = directory.appendingPathComponent("\(name).powerup-backup-\(counter)")
            if fm.fileExists(atPath: candidate.path) { continue }
            try? fm.copyItem(at: url, to: candidate)
            return
        }
    }
}
