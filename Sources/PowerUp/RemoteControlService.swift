import Foundation
import Combine
import AppKit
import ApplicationServices
import CoreGraphics

/// Thread-safe holder so the `nonisolated static` cmux subprocess helpers can
/// read the socket password set from the main actor.
private final class CmuxPasswordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - CmuxWorkspace

/// One row of `cmux list-workspaces`.
///
/// Sample output (with `CMUX_QUIET=1`, which suppresses the legacy-alias notice):
/// ```
/// * workspace:11  ⠐ Build PS5 controller voice app  [selected]
///   workspace:7   ✳ Design the WeChat mini program
/// ```
/// The leading `*` and the trailing `[selected]` tag both mark the selected row.
/// The Rust core parses the rows (`CoreBridge.parseWorkspaces`, cases:
/// `Tests/Fixtures/text-safety/cmux-workspaces.json`).
struct CmuxWorkspace: Identifiable, Hashable {
    let ref: String        // "workspace:11"
    let title: String      // "Build PS5 controller voice app"
    let selected: Bool

    var id: String { ref }

    /// "11 · Build PS5 controller voice app" — short label for pickers.
    var displayName: String {
        let shortRef = ref.hasPrefix("workspace:") ? String(ref.dropFirst("workspace:".count)) : ref
        return title.isEmpty ? shortRef : "\(shortRef) · \(title)"
    }
}

// MARK: - RemoteInjector

/// Where remote mode's text and keys are delivered, when something other than
/// the real routes should receive them. Internal test seam (#118): a test
/// injects a recorder so remote mode never types into the person's real
/// terminal. Production passes nothing and keeps the cmux / Accessibility
/// typing routes below. Completions are called on the main actor, once.
@MainActor
protocol RemoteInjector: AnyObject {
    func injectText(_ text: String, submit: Bool, config: AppConfig,
                    completion: @escaping (String?) -> Void)
    func injectKey(_ key: RemoteControlService.RemoteKey, config: AppConfig,
                   completion: @escaping (String?) -> Void)
}

// MARK: - RemoteControlService

/// Delivers text and keystrokes into a Claude Code session PowerUp does not own.
///
/// Two routes:
/// - **cmux** — shells out to the cmux CLI, which talks to the running cmux app
///   over its Unix socket. No Accessibility permission needed.
/// - **keystroke injection** — synthesises `CGEvent`s into the frontmost app (or
///   a chosen app). Requires Accessibility trust.
///
/// Every subprocess and every event post happens off the main thread; all
/// completions are hopped back to the main actor and called exactly once.
///
/// The text safety rules live in the Rust core since slice 2.5 (DESIGN
/// v2.14), reached through `CoreBridgeTextSafety.swift`: flattening line
/// breaks, the escape-safe `cmux send` segments, parsing `cmux
/// list-workspaces` and its titles' activity glyphs, and the friendly
/// message for a failed cmux command. This type keeps the injector: the
/// route choice, running cmux (the `--` separator, the pauses, the
/// deadlines, the socket password), the target choice and the
/// Accessibility typing. A core failure never lets raw text through: the
/// text is not sent and the person is told why.
@MainActor
final class RemoteControlService: ObservableObject {

    enum RemoteKey {
        case enter
        case escape
        case shiftTab

        /// Key name understood by `cmux send-key` (verified: `enter`, `ctrl+c`
        /// appear in its help, so modifiers use the `mod+key` form).
        var cmuxName: String {
            switch self {
            case .enter: return "enter"
            case .escape: return "escape"
            case .shiftTab: return "shift+tab"
            }
        }

        /// Virtual key code for the CGEvent injection route.
        var keyCode: CGKeyCode {
            switch self {
            case .enter: return 36      // kVK_Return
            case .escape: return 53     // kVK_Escape
            case .shiftTab: return 48   // kVK_Tab (with Shift)
            }
        }

        var modifierFlags: CGEventFlags {
            switch self {
            case .enter, .escape: return []
            case .shiftTab: return .maskShift
            }
        }

        var displayName: String {
            switch self {
            case .enter: return "Enter"
            case .escape: return "Escape"
            case .shiftTab: return "Shift-Tab"
            }
        }
    }

    // MARK: Published state

    @Published private(set) var axTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var cmuxAvailable: Bool = false
    @Published private(set) var cmuxWorkspaces: [CmuxWorkspace] = []
    /// Human-readable reason cmux is unavailable (nil when reachable), e.g. the
    /// socket was refused because cmux's automation access is off.
    @Published private(set) var cmuxStatusDetail: String? = nil

    // MARK: Private state

    /// Everything that blocks (subprocesses, event posting with inter-chunk
    /// pauses) runs here, serially, so two button presses can't interleave
    /// half-typed text.
    private let workQueue = DispatchQueue(label: "com.powerup.remote", qos: .utility)

    private var isRefreshing = false
    private var axRecheckCount = 0

    /// Replaces every delivery route when set (test seam); nil in the app.
    private let injector: (any RemoteInjector)?

    /// - Parameter injector: nil (the app) delivers through cmux or
    ///   Accessibility typing; a test passes a recorder.
    init(injector: (any RemoteInjector)? = nil) {
        self.injector = injector
    }

    // MARK: - Status

    /// Probes cmux (binary + `ping` + workspace list) and Accessibility trust,
    /// then republishes the results on the main actor. Cheap to call from UI;
    /// overlapping calls collapse into one.
    func refreshStatus() {
        guard !isRefreshing else { return }
        isRefreshing = true

        workQueue.async { [weak self] in
            let trusted = AXIsProcessTrusted()
            var available = false
            var workspaces: [CmuxWorkspace] = []
            var detail: String? = nil

            if let binary = RemoteControlService.resolveCmuxBinary() {
                let ping = RemoteControlService.runCmux(binary: binary, arguments: ["ping"], timeout: 6)
                available = ping.status == 0
                    && ping.standardOutput.uppercased().contains("PONG")
                if available {
                    let list = RemoteControlService.runCmux(binary: binary,
                                                           arguments: ["list-workspaces"],
                                                           timeout: 6)
                    if list.status == 0 {
                        // A list the core could not read shows no workspaces;
                        // sending re-reads it and says so (resolveTargetArguments).
                        workspaces = CoreBridge.parseWorkspaces(list.standardOutput) ?? []
                    }
                } else {
                    detail = CoreBridge.failureMessage(action: "Reaching cmux", result: ping)
                }
            } else {
                detail = RemoteControlService.cmuxMissingMessage
            }

            let resolved = workspaces
            let isAvailable = available
            let statusDetail = detail
            guard let service = self else { return }
            Task { @MainActor in
                service.axTrusted = trusted
                service.cmuxAvailable = isAvailable
                service.cmuxWorkspaces = resolved
                service.cmuxStatusDetail = statusDetail
                service.isRefreshing = false
            }
        }
    }

    /// Shows the system Accessibility prompt (only the first time per app
    /// identity; afterwards it silently reports the current answer). Trust is
    /// granted out-of-process, so the result is re-checked a few times after.
    func requestAXTrust() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(options)

        if !axTrusted {
            axRecheckCount = 20
            scheduleAXRecheck()
        }
    }

    /// Polls `AXIsProcessTrusted()` for a while after prompting, so the UI flips
    /// as soon as the user ticks the box in System Settings.
    private func scheduleAXRecheck() {
        guard axRecheckCount > 0 else { return }
        axRecheckCount -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let service = self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != service.axTrusted { service.axTrusted = trusted }
            if trusted {
                service.axRecheckCount = 0
            } else {
                service.scheduleAXRecheck()
            }
        }
    }

    // MARK: - Sending

    /// Types `text` into the configured target, optionally pressing Enter after.
    /// `completion` receives nil on success or a user-facing error string.
    func sendText(_ text: String,
                  submit: Bool,
                  config: AppConfig,
                  completion: @escaping (String?) -> Void) {

        // A literal newline delivered into a terminal surface *is* Enter — a
        // multi-line prompt (Option+Return, pasted text) would submit its first
        // line alone as a truncated instruction and then Enter the rest again.
        // Flatten real line breaks so the prompt arrives as one prompt (the
        // core's rule, cases: Tests/Fixtures/text-safety/line-breaks.json).
        // If the core cannot, nothing is typed: the raw text could submit early.
        guard let text = CoreBridge.flattenLineBreaks(text) else {
            RemoteControlService.finish(RemoteControlService.textNotPreparedMessage, completion)
            return
        }

        if let injector {
            injector.injectText(text, submit: submit, config: config, completion: completion)
            return
        }

        switch RemoteControlService.route(for: config) {
        case .cmux:
            let workspace = RemoteControlService.trimmedOrNil(config.remoteCmuxWorkspace)
            let surface = RemoteControlService.trimmedOrNil(config.remoteCmuxSurface)
            workQueue.async {
                let error = RemoteControlService.cmuxSendText(text,
                                                             submit: submit,
                                                             workspace: workspace,
                                                             surface: surface)
                RemoteControlService.finish(error, completion)
            }

        case .injection(let bundleID):
            guard requireAXTrust(completion) else { return }
            workQueue.async {
                if let activationError = RemoteControlService.activateIfNeeded(bundleID: bundleID) {
                    RemoteControlService.finish(activationError, completion)
                    return
                }
                let error = RemoteControlService.typeText(text, submit: submit)
                RemoteControlService.finish(error, completion)
            }
        }
    }

    /// Presses a single key in the configured target.
    func sendKey(_ key: RemoteKey,
                 config: AppConfig,
                 completion: @escaping (String?) -> Void) {

        if let injector {
            injector.injectKey(key, config: config, completion: completion)
            return
        }

        switch RemoteControlService.route(for: config) {
        case .cmux:
            let workspace = RemoteControlService.trimmedOrNil(config.remoteCmuxWorkspace)
            let surface = RemoteControlService.trimmedOrNil(config.remoteCmuxSurface)
            workQueue.async {
                let error = RemoteControlService.cmuxSendKey(key,
                                                            workspace: workspace,
                                                            surface: surface)
                RemoteControlService.finish(error, completion)
            }

        case .injection(let bundleID):
            guard requireAXTrust(completion) else { return }
            workQueue.async {
                if let activationError = RemoteControlService.activateIfNeeded(bundleID: bundleID) {
                    RemoteControlService.finish(activationError, completion)
                    return
                }
                RemoteControlService.postKey(key.keyCode, flags: key.modifierFlags)
                RemoteControlService.finish(nil, completion)
            }
        }
    }

    /// Re-checks trust at call time (the user may have granted it since the last
    /// probe) and reports the standard error when it's still missing.
    private func requireAXTrust(_ completion: @escaping (String?) -> Void) -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted { axTrusted = trusted }
        guard trusted else {
            RemoteControlService.finish("Grant Accessibility access in Settings → Remote", completion)
            return false
        }
        return true
    }

    // MARK: - Routing

    /// How remote text and keys are delivered. The route and the target
    /// choice are the injector's and stay in Swift (DESIGN v2.14 C); they are
    /// internal so `RemoteRoutingTests` can pin them (HK-204, HK-208, HK-209).
    enum Route: Equatable {
        case cmux
        case injection(bundleID: String?)   // nil = frontmost app
    }

    /// "frontmost" types into the frontmost app with no activation, "app"
    /// into the configured bundle id (trimmed; blank means nil), and every
    /// other kind goes to cmux (HK-208, HK-209).
    nonisolated static func route(for config: AppConfig) -> Route {
        switch config.remoteTargetKind {
        case "frontmost":
            return .injection(bundleID: nil)
        case "app":
            return .injection(bundleID: trimmedOrNil(config.remoteAppBundleID))
        default:
            // "cmux" and anything unrecognised (a hand-edited config) — cmux is
            // the safe default because it needs no special permission.
            return .cmux
        }
    }

    /// A configured value trimmed of `whitespacesAndNewlines`; nil when
    /// nothing is left (HK-209).
    nonisolated static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Delivers a completion exactly once, on the main actor.
    private nonisolated static func finish(_ message: String?,
                                           _ completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            completion(message)
        }
    }

    /// What the person is told when the core could not make text safe to type
    /// (a core bug): nothing was sent, rather than text that might submit.
    private nonisolated static let textNotPreparedMessage =
        "PowerUp couldn't make that text safe to type, so it didn't send anything. Try again."

    // MARK: - cmux route (background)

    private nonisolated static func cmuxSendText(_ text: String,
                                                 submit: Bool,
                                                 workspace: String?,
                                                 surface: String?) -> String? {
        guard let binary = resolveCmuxBinary() else { return cmuxMissingMessage }

        // `cmux send` turns the two-character sequences backslash-n, -r and -t
        // into Enter and Tab; a backslash that ends a send is delivered
        // literally (verified live), so the core splits the text right after
        // such a backslash, one send per segment, ordinary text in exactly one
        // (cases: Tests/Fixtures/text-safety/segmentation.json). If the core
        // cannot, nothing is sent rather than text cmux would reinterpret.
        guard let segments = CoreBridge.escapeSafeSegments(text) else { return textNotPreparedMessage }

        let target: [String]
        switch resolveTargetArguments(binary: binary, workspace: workspace, surface: surface) {
        case .resolved(let arguments): target = arguments
        case .failed(let message): return message
        }

        // The "--" separator is essential: without it, dictated text that starts
        // with a dash ("--force it") would be parsed as a cmux flag.
        for (index, segment) in segments.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 0.03) }
            let send = runCmux(binary: binary, arguments: ["send"] + target + ["--", segment], timeout: 10)
            if send.status != 0 || send.spawnFailed {
                return CoreBridge.failureMessage(action: "Sending text to cmux", result: send)
            }
        }

        guard submit else { return nil }

        // Give the target TUI a beat to absorb the paste before the newline.
        Thread.sleep(forTimeInterval: 0.12)

        let enter = runCmux(binary: binary,
                            arguments: ["send-key"] + target + ["--", RemoteKey.enter.cmuxName],
                            timeout: 10)
        if enter.status != 0 || enter.spawnFailed {
            return CoreBridge.failureMessage(action: "Pressing Enter in cmux", result: enter)
        }
        return nil
    }

    private nonisolated static func cmuxSendKey(_ key: RemoteKey,
                                                workspace: String?,
                                                surface: String?) -> String? {
        guard let binary = resolveCmuxBinary() else { return cmuxMissingMessage }

        let target: [String]
        switch resolveTargetArguments(binary: binary, workspace: workspace, surface: surface) {
        case .resolved(let arguments): target = arguments
        case .failed(let message): return message
        }

        let result = runCmux(binary: binary,
                             arguments: ["send-key"] + target + ["--", key.cmuxName],
                             timeout: 10)
        if result.status != 0 || result.spawnFailed {
            return CoreBridge.failureMessage(action: "Sending \(key.displayName) to cmux", result: result)
        }
        return nil
    }

    private nonisolated static let cmuxMissingMessage =
        "Couldn't find the cmux CLI — install cmux, or pick a different remote target in Settings → Remote."

    /// Either the resolved `--workspace`/`--surface` arguments, or a
    /// user-facing reason we couldn't work out where to type.
    private enum TargetArguments {
        case resolved([String])
        case failed(String)
    }

    /// Builds the `--workspace`/`--surface` arguments, resolving "auto" to the
    /// workspace cmux currently has selected.
    private nonisolated static func resolveTargetArguments(binary: String,
                                                           workspace: String?,
                                                           surface: String?) -> TargetArguments {
        var reference = workspace
        if reference == nil {
            let list = runCmux(binary: binary, arguments: ["list-workspaces"], timeout: 6)
            guard list.status == 0, !list.spawnFailed else {
                return .failed(CoreBridge.failureMessage(action: "Listing cmux workspaces", result: list))
            }
            // A list the core could not read is never taken for "no
            // workspaces", and nothing in it is ever chosen as the target.
            guard let workspaces = CoreBridge.parseWorkspaces(list.standardOutput) else {
                return .failed("PowerUp couldn't read cmux's workspace list — pick a workspace in Settings → Remote.")
            }
            guard let chosen = autoTargetWorkspace(in: workspaces) else {
                return .failed("cmux has no open workspaces — open one, or pick a workspace in Settings → Remote.")
            }
            reference = chosen.ref
        }
        return .resolved(targetArguments(workspace: reference, surface: surface))
    }

    /// The workspace "auto" types into (HK-204): the one cmux has selected,
    /// else the first listed; nil when cmux lists none, and then the person
    /// is told to open one.
    nonisolated static func autoTargetWorkspace(in workspaces: [CmuxWorkspace]) -> CmuxWorkspace? {
        workspaces.first(where: { $0.selected }) ?? workspaces.first
    }

    /// `--workspace` before `--surface`, each only when it is set and not
    /// empty (HK-204).
    nonisolated static func targetArguments(workspace: String?, surface: String?) -> [String] {
        var arguments: [String] = []
        if let workspace, !workspace.isEmpty {
            arguments.append(contentsOf: ["--workspace", workspace])
        }
        if let surface, !surface.isEmpty {
            arguments.append(contentsOf: ["--surface", surface])
        }
        return arguments
    }

    // MARK: - cmux binary resolution

    /// `/Applications/cmux.app/…/bin/cmux` first (the documented location), then
    /// a login-shell lookup, then the usual install spots.
    nonisolated static func resolveCmuxBinary() -> String? {
        let bundled = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        if isRunnableFile(bundled) { return bundled }

        if let fromShell = cachedLoginShellCmuxPath, isRunnableFile(fromShell) { return fromShell }

        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
            home + "/.local/bin/cmux",
            home + "/.npm-global/bin/cmux"
        ]
        return candidates.first(where: isRunnableFile)
    }

    private nonisolated static func isRunnableFile(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// `/bin/zsh -l -c 'command -v cmux'`, bounded so a slow profile can't wedge
    /// the caller. Only absolute paths are accepted (a shell function prints a
    /// bare name).
    fileprivate nonisolated static func loginShellCmuxLookup() -> String? {
        guard isRunnableFile("/bin/zsh") else { return nil }
        let result = runProcess(executable: "/bin/zsh",
                                arguments: ["-l", "-c", "command -v cmux"],
                                environment: nil,
                                timeout: 2.5)
        guard result.status == 0, !result.spawnFailed, !result.timedOut else { return nil }
        for rawLine in result.standardOutput.split(separator: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("/") { return line }
        }
        return nil
    }

    // MARK: - Subprocess plumbing (background only)

    /// A finished command, as the core's friendly failure message reads it
    /// (`CoreBridge.failureMessage`, cases:
    /// `Tests/Fixtures/text-safety/failure-message.json`).
    struct CommandResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
        let timedOut: Bool
        let spawnFailed: Bool
    }

    private nonisolated static func runCmux(binary: String,
                                            arguments: [String],
                                            timeout: TimeInterval) -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        // Suppresses the legacy-alias notice that would otherwise pollute
        // list-workspaces output.
        environment["CMUX_QUIET"] = "1"
        // cmux's default socket mode ("cmuxOnly") rejects a Finder-launched app
        // like us; the user enables Automation → Password mode in cmux and enters
        // the same password here, which we pass through so the socket accepts us.
        if let password = cmuxSocketPassword.value, !password.isEmpty {
            environment["CMUX_SOCKET_PASSWORD"] = password
        }
        return runProcess(executable: binary,
                          arguments: arguments,
                          environment: environment,
                          timeout: timeout)
    }

    /// Keeps the cmux socket password reachable from the `nonisolated static`
    /// subprocess helpers. AppState calls `updateCmuxPassword` whenever the
    /// config's `remoteCmuxPassword` changes.
    nonisolated static func updateCmuxPassword(_ password: String?) {
        cmuxSocketPassword.value = (password?.isEmpty == true) ? nil : password
    }

    private nonisolated static let cmuxSocketPassword = CmuxPasswordBox()

    /// Runs a command to completion with a hard deadline. Both pipes are drained
    /// concurrently so a chatty child can never fill a pipe buffer and deadlock.
    private nonisolated static func runProcess(executable: String,
                                               arguments: [String],
                                               environment: [String: String]?,
                                               timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.setStandardOutput(outPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.setStandardError(errPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            // Unblock the readers: nothing will ever write to these pipes.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = readers.wait(timeout: .now() + 1)
            return CommandResult(status: -1,
                                 standardOutput: "",
                                 standardError: error.localizedDescription,
                                 timedOut: false,
                                 spawnFailed: true)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) != .success {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        process.terminationHandler = nil
        _ = readers.wait(timeout: .now() + 2)

        return CommandResult(status: process.isRunning ? -1 : process.terminationStatus,
                             standardOutput: collector.standardOutputText(),
                             standardError: collector.standardErrorText(),
                             timedOut: timedOut,
                             spawnFailed: false)
    }

    // MARK: - Keystroke injection (background only)

    /// Brings the target app forward and waits for it to settle. Returns a
    /// user-facing message on failure, nil on success (including "frontmost",
    /// which needs no activation).
    private nonisolated static func activateIfNeeded(bundleID: String?) -> String? {
        guard let bundleID else { return nil }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = running.first(where: { !$0.isTerminated }) else {
            return "\(friendlyAppName(for: bundleID)) isn't running — open it first."
        }
        app.activate()

        // Activation is asynchronous: return the instant the target actually
        // becomes frontmost so the first injected keystrokes don't land in the
        // previously-focused window. Poll briefly, then proceed regardless —
        // a best-effort send beats hanging if focus never settles.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// A readable name for a bundle id — the known-terminal name when we have
    /// one, otherwise the raw bundle id.
    private nonisolated static func friendlyAppName(for bundleID: String) -> String {
        AppConfig.knownTerminalApps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    /// Types `text` as Unicode keyboard events, then optionally presses Enter.
    private nonisolated static func typeText(_ text: String, submit: Bool) -> String? {
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: .combinedSessionState)

        var index = 0
        while index < units.count {
            var end = min(index + maxUnicodeChunk, units.count)
            // Never split a surrogate pair across two events.
            if end < units.count, isHighSurrogate(units[end - 1]) { end -= 1 }
            if end <= index { end = min(index + maxUnicodeChunk, units.count) }

            let chunk = Array(units[index..<end])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return "Couldn't create a keyboard event — try the cmux target instead."
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            // Events created from the combined-session source inherit whatever
            // modifiers are physically held right now — a user still holding ⌘
            // or ⌥ from the controller grip would turn every injected character
            // into a menu shortcut. These are plain text: clear the flags.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)

            index = end
            if index < units.count { Thread.sleep(forTimeInterval: 0.002) }
        }

        if submit {
            Thread.sleep(forTimeInterval: 0.05)
            postKey(RemoteKey.enter.keyCode, flags: RemoteKey.enter.modifierFlags)
        }
        return nil
    }

    /// CGEventKeyboardSetUnicodeString is documented as unreliable for long
    /// strings; 20 UTF-16 units per event is comfortably inside the safe range.
    private nonisolated static let maxUnicodeChunk = 20

    private nonisolated static func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private nonisolated static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }

        // Bracket a Shift-modified key with a matching flagsChanged press, so a
        // target that tracks modifiers from flagsChanged events (rather than
        // from the key event's own flags) also sees the Shift go down.
        if flags.contains(.maskShift),
           let press = CGEvent(keyboardEventSource: source, virtualKey: kVKShift, keyDown: true) {
            press.type = .flagsChanged
            press.flags = .maskShift
            press.post(tap: .cgSessionEventTap)
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        // Explicitly release Shift afterwards: a modifier left down would leak
        // into whatever the user types next. But only when the user isn't
        // *physically* holding Shift (checked against the hardware HID state,
        // which our synthetic events don't pollute) — clearing a genuinely held
        // modifier out from under them would be just as wrong.
        if flags.contains(.maskShift),
           !CGEventSource.flagsState(.hidSystemState).contains(.maskShift),
           let release = CGEvent(keyboardEventSource: source, virtualKey: kVKShift, keyDown: false) {
            release.type = .flagsChanged
            release.flags = []
            release.post(tap: .cgSessionEventTap)
        }
    }

    private nonisolated static let kVKShift: CGKeyCode = 56   // kVK_Shift
}

// MARK: - Login-shell lookup cache

/// Login shells are slow to start, so `command -v cmux` runs at most once per
/// app run. Swift global `let`s initialise lazily and thread-safely.
private let cachedLoginShellCmuxPath: String? = RemoteControlService.loginShellCmuxLookup()

// MARK: - OutputCollector

/// Lock-protected mailbox for the two pipe-reader threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func setStandardOutput(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        outData = data
    }

    func setStandardError(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        errData = data
    }

    func standardOutputText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: outData, as: UTF8.self)
    }

    func standardErrorText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errData, as: UTF8.self)
    }
}
