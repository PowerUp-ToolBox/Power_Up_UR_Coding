import Foundation
import PowerUpCore

/// The text safety rules of remote mode (slice 2.5, DESIGN v2.14): the core
/// owns flattening dictated text, splitting it into escape-safe cmux sends,
/// parsing `cmux list-workspaces`, stripping a title's activity glyph,
/// condensing cmux output and the friendly message for a failed cmux
/// command; RemoteControlService keeps the injector: running cmux (the `--`
/// separator, the pauses, the deadlines, the socket password), the route
/// choice and the Accessibility typing.
///
/// These run on RemoteControlService's background queue; like every
/// `CoreBridge` function, they are safe from any thread. A failed flatten or
/// segmentation must never let the raw text through, since a line break
/// typed into a terminal is Enter: those wrappers answer nil and the caller
/// sends nothing and tells the person.
extension CoreBridge {
    /// The text with every line break flattened to a space, a run of them
    /// to one; nil when the core fails, and then nothing may be typed.
    static func flattenLineBreaks(_ text: String) -> String? {
        call("flattenLineBreaks", fallback: nil) { try PowerUpCore.flattenLineBreaks(text: text) }
    }

    /// The flattened text as `cmux send` segments cmux cannot reinterpret
    /// (empty text: no segment); nil when the core fails, and then nothing
    /// is sent.
    static func escapeSafeSegments(_ text: String) -> [String]? {
        call("escapeSafeSegments", fallback: nil) { try PowerUpCore.escapeSafeSegments(text: text) }
    }

    /// `cmux list-workspaces` output as rows; nil when the core fails, which
    /// the caller treats as a list it could not read (never as a target).
    static func parseWorkspaces(_ output: String) -> [CmuxWorkspace]? {
        call("parseWorkspaces", fallback: nil) {
            try PowerUpCore.parseWorkspaces(output: output).map(CmuxWorkspace.init)
        }
    }

    /// A workspace title without its leading activity glyph; nil when the
    /// core fails.
    static func stripStatusGlyph(_ title: String) -> String? {
        call("stripStatusGlyph", fallback: nil) { try PowerUpCore.stripStatusGlyph(title: title) }
    }

    /// cmux output as one line of at most `maxChars` characters; nil when
    /// the core fails.
    static func condense(_ text: String, maxChars: Int) -> String? {
        call("condense", fallback: nil) {
            try PowerUpCore.condense(text: text, maxChars: Int64(maxChars))
        }
    }

    /// The friendly message for a cmux command `action` names that failed
    /// as `result` says. When the core fails it is "<action> failed.", so
    /// the failure is still reported.
    static func failureMessage(action: String, result: RemoteControlService.CommandResult) -> String {
        call("failureMessage", fallback: "\(action) failed.") {
            try PowerUpCore.failureMessage(action: action, result: result.core)
        }
    }
}

// MARK: - Conversions

fileprivate extension CmuxWorkspace {
    init(_ core: CoreCmuxWorkspace) {
        self.init(ref: core.reference, title: core.title, selected: core.selected)
    }
}

fileprivate extension RemoteControlService.CommandResult {
    var core: CoreCommandResult {
        CoreCommandResult(status: Int64(status), standardOutput: standardOutput,
                          standardError: standardError, timedOut: timedOut,
                          spawnFailed: spawnFailed)
    }
}
