import Foundation

/// Decides whether a harness permission request looks DESTRUCTIVE — the kind
/// of action a single misheard word or stray button press must never approve
/// (issue #47): deleting files, rewriting git history, force-pushing,
/// dropping databases, formatting disks. Destructive requests require a
/// second Approve press to confirm.
///
/// Deliberately conservative and pattern-based: a false positive costs one
/// extra button press; a false negative costs somebody's branch. Patterns are
/// matched case-insensitively against the tool kind, title, and detail. The
/// rule and its pattern list live in the Rust core
/// (`harness::destructive`, DESIGN v2.12), where the session machine
/// classifies every request; this is a thin wrapper for the app's own
/// callers and tests.
enum DestructiveActionClassifier {

    /// Substring patterns (lowercased) that mark a command/title destructive.
    static var patterns: [String] { CoreBridge.destructivePatterns() }

    /// True when the core fails: the safe side costs one extra press.
    static func isDestructive(kind: String, title: String, detail: String) -> Bool {
        CoreBridge.isDestructive(kind: kind, title: title, detail: detail)
    }
}
