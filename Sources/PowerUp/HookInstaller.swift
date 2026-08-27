import Foundation

/// Installs (and removes) the Claude Code hooks that give PowerUp voice
/// read-back from *any* claude session on this machine — terminal, cmux, or
/// PowerUp's own.
///
/// Hooks live in `~/.claude/settings.json`, a file the user owns and that other
/// tools also write to, so every edit here is conservative: unknown keys are
/// copied through verbatim, a numbered backup is taken before writing, and a
/// settings file that isn't valid JSON is left completely untouched.
///
/// The settings path is injectable so the merge logic can be exercised against a
/// throwaway copy without going anywhere near the real file.
enum HookInstaller {

    /// Hook events PowerUp subscribes to, in a stable order. SessionEnd is
    /// how a session that closes MID-TURN releases the "Claude is working"
    /// state — its Stop hook never fires, and without SessionEnd the light
    /// bar would stay amber forever. PostToolUse is the turn HEARTBEAT: it
    /// fires on every tool call, keeping long working turns visibly alive.
    static let hookEvents = ["Stop", "UserPromptSubmit", "Notification", "SessionEnd", "PostToolUse"]

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
    static func hookCommand() -> String {
        shellSingleQuoted(hookScriptURL().path)
    }

    /// Wraps a value in single quotes for the shell, escaping embedded quotes
    /// with the standard `'\''` dance.
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The real `~/.claude/settings.json`.
    static var defaultSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(hookScriptBody(port: port, token: token).utf8)
                .write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                  ofItemAtPath: url.path)
        } catch {
            throw HookError.fileError("Couldn't write the hook script to \(url.path): \(error.localizedDescription)")
        }
    }

    static func hookScriptBody(port: Int, token: String) -> String {
        let quotedToken = shellDoubleQuoted(token)
        let safePort = max(1, min(65535, port))
        return """
        #!/bin/bash
        # PowerUp hook — forwards Claude Code hook events to the PowerUp app.
        #
        # Generated by PowerUp (Settings → Remote). Safe to delete: without it the
        # app simply loses spoken read-back from terminal/cmux sessions.
        #
        # stdin is consumed BEFORE curl is backgrounded, so the payload can never
        # be lost, and the script always exits 0 immediately — Claude is never
        # delayed or blocked by PowerUp being closed, busy, or on another port.
        payload=$(cat)
        curl -s -o /dev/null --max-time 1 \\
             -X POST \\
             -H "Content-Type: application/json" \\
             -H "X-PowerUp-Token: \(quotedToken)" \\
             --data-binary "$payload" \\
             "http://127.0.0.1:\(safePort)/event" >/dev/null 2>&1 &
        exit 0

        """
    }

    /// Escapes a value for interpolation inside a double-quoted bash string.
    private static func shellDoubleQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\", "\"", "$", "`":
                escaped.append("\\")
                escaped.append(character)
            case "\n", "\r":
                continue                    // a token never contains newlines
            default:
                escaped.append(character)
            }
        }
        return escaped
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
        guard let root = try? readSettings(at: settingsURL),
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["Stop"] as? [Any] else { return false }
        return groups.contains { group(($0), references: acceptedCommands()) }
    }

    /// Full status for the Settings UI: not just "is the path registered", but
    /// "will the hooks actually reach the listener as configured right now".
    /// The registration alone can look fine while the script still posts to a
    /// port the listener left long ago — that drift is exactly what this catches.
    static func installState(port: Int,
                             token: String,
                             settingsURL: URL = HookInstaller.defaultSettingsURL) -> InstallState {
        guard let root = try? readSettings(at: settingsURL),
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["Stop"] as? [Any] else { return .notInstalled }

        let quoted = hookCommand()
        let legacy = hookScriptURL().path
        let hasQuoted = groups.contains { group($0, references: [quoted]) }
        let hasLegacy = groups.contains { group($0, references: [legacy]) }
        guard hasQuoted || hasLegacy else { return .notInstalled }

        // A legacy unquoted registration never executes (the space in
        // "Application Support" splits the command) — always stale.
        guard hasQuoted else { return .outOfDate }

        // An install from an older build may be missing events added since
        // (e.g. SessionEnd) — reinstalling brings them in.
        for event in hookEvents {
            guard let eventGroups = hooks[event] as? [Any],
                  eventGroups.contains(where: { group($0, references: [quoted]) }) else {
                return .outOfDate
            }
        }

        guard let data = try? Data(contentsOf: hookScriptURL()) else { return .outOfDate }
        let body = String(decoding: data, as: UTF8.self)
        return body == hookScriptBody(port: port, token: token) ? .installed : .outOfDate
    }

    /// Every command string that counts as "ours": the current quoted form plus
    /// the legacy unquoted path (so old installs are recognised and upgraded).
    private static func acceptedCommands() -> [String] {
        [hookCommand(), hookScriptURL().path]
    }

    // MARK: - Install / uninstall

    /// Rewrites the hook script and merges our entries into the settings file.
    /// Idempotent: running it twice leaves exactly one entry per event.
    static func install(port: Int,
                        token: String,
                        settingsURL: URL = HookInstaller.defaultSettingsURL) throws {
        try writeHookScript(port: port, token: token)

        let command = hookCommand()
        let legacyPath = hookScriptURL().path
        var root = try readSettings(at: settingsURL)

        var hooks: [String: Any]
        if let existing = root["hooks"] {
            guard let dictionary = existing as? [String: Any] else {
                throw HookError.unexpectedShape(
                    "The \"hooks\" section of \(settingsURL.path) isn't in the expected format, so PowerUp left it alone.")
            }
            hooks = dictionary
        } else {
            hooks = [:]
        }

        var changed = false
        for event in hookEvents {
            var groups: [Any]
            if let existing = hooks[event] {
                guard let array = existing as? [Any] else {
                    throw HookError.unexpectedShape(
                        "The \"\(event)\" hooks in \(settingsURL.path) aren't in the expected format, so PowerUp left them alone.")
                }
                groups = array
            } else {
                groups = []
            }

            // Upgrade any legacy unquoted registration in place — the shell
            // splits its embedded spaces, so it has never actually run.
            if groups.contains(where: { group($0, references: [legacyPath]) }) {
                groups = removeEntries(matching: [legacyPath], from: groups)
                changed = true
            }

            guard !groups.contains(where: { group($0, references: [command]) }) else {
                hooks[event] = groups
                continue
            }
            groups.append(["hooks": [["type": "command", "command": command]]] as [String: Any])
            hooks[event] = groups
            changed = true
        }

        guard changed else { return }
        root["hooks"] = hooks
        try writeSettings(root, to: settingsURL)
    }

    /// Removes only the entries whose command is our script, pruning any group,
    /// event array, or `hooks` object left empty by the removal.
    static func uninstall(settingsURL: URL = HookInstaller.defaultSettingsURL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        let commands = acceptedCommands()
        var root = try readSettings(at: settingsURL)
        guard let existingHooks = root["hooks"] else { return }
        guard var hooks = existingHooks as? [String: Any] else {
            throw HookError.unexpectedShape(
                "The \"hooks\" section of \(settingsURL.path) isn't in the expected format, so PowerUp left it alone.")
        }

        var changed = false
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [Any] else { continue }

            var rebuilt: [Any] = []
            for element in groups {
                guard var groupDictionary = element as? [String: Any],
                      let entries = groupDictionary["hooks"] as? [Any] else {
                    rebuilt.append(element)
                    continue
                }
                let kept = entries.filter { !entry($0, references: commands) }
                if kept.count == entries.count {
                    rebuilt.append(element)
                    continue
                }
                changed = true
                guard !kept.isEmpty else { continue }        // prune the empty group
                groupDictionary["hooks"] = kept
                rebuilt.append(groupDictionary)
            }

            if rebuilt.isEmpty {
                hooks.removeValue(forKey: event)             // prune the empty event
            } else {
                hooks[event] = rebuilt
            }
        }

        guard changed else { return }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Settings file I/O

    /// Reads the settings file into a dictionary. A missing (or blank) file
    /// starts from `{}`; anything that isn't a JSON object throws, and the
    /// caller must then leave the file alone.
    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HookError.fileError("Couldn't read \(url.path): \(error.localizedDescription)")
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }

        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = parsed as? [String: Any] else {
            throw HookError.invalidSettings(url.path)
        }
        return root
    }

    /// Backs the current file up, then writes the merged object atomically.
    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw HookError.unexpectedShape("PowerUp couldn't rewrite \(url.path) safely, so it left it alone.")
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw HookError.unexpectedShape("PowerUp couldn't rewrite \(url.path) safely, so it left it alone.")
        }

        backUp(url)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var payload = data
            payload.append(0x0A)   // trailing newline, like every other editor writes
            try payload.write(to: url, options: .atomic)
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

    // MARK: - Matching helpers

    /// True when a hook *group* (`{"hooks":[…]}`) contains one of our commands.
    private static func group(_ element: Any, references commands: [String]) -> Bool {
        guard let dictionary = element as? [String: Any],
              let entries = dictionary["hooks"] as? [Any] else { return false }
        return entries.contains { entry($0, references: commands) }
    }

    /// True when a single hook entry (`{"type":"command","command":"…"}`) is ours.
    private static func entry(_ element: Any, references commands: [String]) -> Bool {
        guard let dictionary = element as? [String: Any],
              let command = dictionary["command"] as? String else { return false }
        return commands.contains(command)
    }

    /// Rebuilds a group array with our matching entries removed, pruning any
    /// group left empty. Unknown shapes are passed through untouched.
    private static func removeEntries(matching commands: [String], from groups: [Any]) -> [Any] {
        var rebuilt: [Any] = []
        for element in groups {
            guard var groupDictionary = element as? [String: Any],
                  let entries = groupDictionary["hooks"] as? [Any] else {
                rebuilt.append(element)
                continue
            }
            let kept = entries.filter { !entry($0, references: commands) }
            if kept.count == entries.count {
                rebuilt.append(element)
                continue
            }
            guard !kept.isEmpty else { continue }
            groupDictionary["hooks"] = kept
            rebuilt.append(groupDictionary)
        }
        return rebuilt
    }
}
