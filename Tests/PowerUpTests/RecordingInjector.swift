import Foundation
@testable import PowerUp

/// A `RemoteInjector` that records what remote mode would deliver instead of
/// typing it anywhere (#118). With it injected, `RemoteControlService` never
/// reaches cmux or the Accessibility typing route, so a test can run remote
/// mode without touching the person's real terminal.
///
/// Every delivery answers synchronously with `failure` (nil = delivered).
@MainActor
final class RecordingInjector: RemoteInjector {

    enum Call: Equatable {
        case text(String, submit: Bool)
        case key(RemoteControlService.RemoteKey)
    }

    private(set) var calls: [Call] = []

    /// The error every delivery reports; nil means it succeeded.
    var failure: String?

    func clearCalls() { calls.removeAll() }

    func injectText(_ text: String, submit: Bool, config: AppConfig,
                    completion: @escaping (String?) -> Void) {
        calls.append(.text(text, submit: submit))
        completion(failure)
    }

    func injectKey(_ key: RemoteControlService.RemoteKey, config: AppConfig,
                   completion: @escaping (String?) -> Void) {
        calls.append(.key(key))
        completion(failure)
    }
}
