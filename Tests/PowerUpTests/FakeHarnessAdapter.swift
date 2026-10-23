import Foundation
@testable import PowerUp

/// A scriptable harness for AppState tests: conforms to the existing
/// `HarnessAdapter` contract unchanged, records every call AppState makes on
/// it, and emits queued `HarnessEvent`s only when the test says so —
/// synchronously, on the caller's (main-actor) stack, so a test never sleeps
/// or waits on an expectation.
///
/// Its lifecycle follows the real adapters (`ClaudeService`, `ACPAdapter`)
/// closely enough for session rules to read it the same way:
/// `start` → `.starting`; an emitted `sessionReady` → `.ready` and fills
/// `sessionID` / `modelName`; an emitted, acknowledged `set_model`
/// `controlResult` → `modelName`; `send` → `.working`; an emitted
/// `turnCompleted` → `.ready`; `stop` or an emitted `ended` → `.stopped`.
/// Every identity field is also settable, so a test can put the fake in any
/// state directly.
///
/// Inject it with `AppStateTestEnvironment.makeAppState(harness:)`.
@MainActor
final class FakeHarnessAdapter: HarnessAdapter {

    /// One call AppState made on the adapter, in the order received.
    enum Call: Equatable {
        case start(HarnessConfiguration)
        case send(String)
        case interrupt
        case setModel(String)
        case setPermissionMode(String)
        case respondToPermission(id: String, allow: Bool)
        case stop
    }

    // MARK: Recorded calls

    private(set) var calls: [Call] = []

    /// Forget what has been recorded so far (e.g. after scripting set-up).
    func clearCalls() { calls.removeAll() }

    // MARK: HarnessAdapter identity

    var state: HarnessState = .stopped
    var sessionID: String?
    var modelName: String?
    var totalCostUSD: Double = 0
    var supportsEffort: Bool = false
    var reportsCostUSD: Bool = false
    var totalTokens: Int = 0

    var onHarnessEvent: ((HarnessEvent) -> Void)?

    // MARK: Scripted events

    /// Events waiting to be emitted, oldest first.
    private(set) var queuedEvents: [HarnessEvent] = []

    /// Appends events to the script; nothing is delivered until `emitNext()`
    /// or `emitAll()`.
    func queue(_ events: HarnessEvent...) {
        queuedEvents.append(contentsOf: events)
    }

    /// Delivers the oldest queued event. Returns it, or nil when the script
    /// is exhausted.
    @discardableResult
    func emitNext() -> HarnessEvent? {
        guard !queuedEvents.isEmpty else { return nil }
        let event = queuedEvents.removeFirst()
        emit(event)
        return event
    }

    /// Delivers every queued event in order, including any queued while
    /// delivering (e.g. from a handler that calls back into the fake).
    func emitAll() {
        while emitNext() != nil {}
    }

    /// Delivers one event immediately, bypassing the queue.
    func emit(_ event: HarnessEvent) {
        apply(event)
        onHarnessEvent?(event)
    }

    // MARK: HarnessAdapter calls

    func start(_ configuration: HarnessConfiguration) {
        calls.append(.start(configuration))
        state = .starting
    }

    func send(_ text: String) {
        calls.append(.send(text))
        state = .working
    }

    func interrupt() {
        calls.append(.interrupt)
    }

    func setModel(_ model: String) {
        calls.append(.setModel(model))
    }

    func setPermissionMode(_ mode: String) {
        calls.append(.setPermissionMode(mode))
    }

    func respondToPermission(id: String, allow: Bool) {
        calls.append(.respondToPermission(id: id, allow: allow))
    }

    func stop() {
        calls.append(.stop)
        state = .stopped
    }

    // MARK: Lifecycle mirroring

    /// What a real adapter's own state would do on emitting `event`, applied
    /// before AppState sees it (the real adapters update first, too).
    private func apply(_ event: HarnessEvent) {
        switch event {
        case .sessionReady(let id, let model):
            sessionID = id
            modelName = model
            if state != .working { state = .ready }
        case .turnCompleted(_, let cost, _, _):
            if let cost { totalCostUSD = cost }
            if state != .stopped { state = .ready }
        case .controlResult(let action, let ok, _, let value):
            // Both real adapters report an acknowledged model switch at once,
            // without waiting for the next init (DESIGN.md v1.3 C).
            if ok, action == "set_model", let value, !value.isEmpty { modelName = value }
        case .ended:
            state = .stopped
        default:
            break
        }
    }
}
