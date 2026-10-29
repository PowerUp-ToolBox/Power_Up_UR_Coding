import Foundation

// MARK: - HarnessState

/// Lifecycle of a harness session. (Historically named for the first harness;
/// the alias is the forward-facing name.)
typealias HarnessState = ClaudeState

// MARK: - HarnessConfiguration

/// Everything a harness adapter needs to start (or resume) a session. Fields a
/// given harness has no equivalent for are simply ignored by its adapter.
struct HarnessConfiguration: Equatable {
    var projectDir: URL
    var model: String              // harness-specific alias; "default" = adapter's default
    var permissionMode: String
    var effort: String             // "default" = don't ask for one
    var resumeSessionID: String?
    var binaryPathOverride: String?
    /// For ACP adapters: the agent command line to spawn (executable + args).
    /// nil for adapters that resolve their own binary (the Claude adapter).
    var agentCommand: [String]? = nil
}

// MARK: - HarnessEvent

/// The normalized event stream every harness adapter produces — the only
/// vocabulary `AppState` consumes. A superset of what the Claude adapter emits:
/// `permissionRequest` and `notification` are reserved for adapters that
/// surface them (see DEVELOPMENT.md WS-B). ACP agents emit `permissionRequest`;
/// the Claude adapter emits neither, so nothing on its path may wait for one.
enum HarnessEvent: Equatable {
    case sessionReady(sessionID: String, model: String)
    case replyDelta(String)                              // streaming text chunk
    case reply(String)                                   // one complete assistant message
    case toolUse(name: String, detail: String)
    case turnCompleted(resultText: String?, costUSD: Double?, isError: Bool, detail: String)
    /// Answer to a control request (interrupt / set model / set permission
    /// mode). Semantics match `ClaudeEvent.controlResult`.
    case controlResult(action: String, ok: Bool, detail: String, value: String?)
    /// The harness is asking the user to approve something. `kind` is the
    /// harness's own tool category ("edit", "execute", "delete", … — empty
    /// when unknown) and feeds the destructive-action classifier.
    case permissionRequest(id: String, name: String, kind: String, detail: String)
    /// The harness wants the user's attention outside a turn (reserved).
    case notification(String)
    case runtimeError(String)
    case ended(exitCode: Int32)

    /// Normalization from the Claude adapter's wire-level events. Total —
    /// every `ClaudeEvent` has exactly one `HarnessEvent` (HK-090); the
    /// mapping runs in the Rust core (DESIGN v2.12).
    static func from(_ event: ClaudeEvent) -> HarnessEvent {
        CoreBridge.harnessEvent(from: event)
    }
}

// MARK: - HarnessAdapter

/// The contract between `AppState` and whatever runs the coding-agent session.
/// `ClaudeService` is the first implementation; the ACP and Codex adapters
/// (DEVELOPMENT.md WS-B) implement the same surface. `AppState`'s session
/// logic must depend only on this protocol and `HarnessEvent` — never on a
/// concrete adapter's own types.
@MainActor
protocol HarnessAdapter: AnyObject {
    var state: HarnessState { get }
    var sessionID: String? { get }
    var modelName: String? { get }
    var totalCostUSD: Double { get }

    // Capability flags — the app degrades honestly instead of faking support.
    var supportsEffort: Bool { get }       // effort switch via restart+resume
    var reportsCostUSD: Bool { get }       // dollar cost in turnCompleted
    /// Total tokens the session has consumed, when the harness reports usage
    /// (the Claude ACP bridge does); 0 when unknown.
    var totalTokens: Int { get }

    /// Always invoked on the main actor.
    var onHarnessEvent: ((HarnessEvent) -> Void)? { get set }

    func start(_ configuration: HarnessConfiguration)
    func send(_ text: String)
    func interrupt()
    func setModel(_ model: String)
    func setPermissionMode(_ mode: String)
    /// Answers a pending `permissionRequest` event by its id. Adapters whose
    /// harness surfaces no permission RPC ignore it.
    func respondToPermission(id: String, allow: Bool)
    func stop()
}

extension HarnessAdapter {
    var supportsEffort: Bool { false }
    var reportsCostUSD: Bool { false }
    var totalTokens: Int { 0 }
    func respondToPermission(id: String, allow: Bool) {}
}
