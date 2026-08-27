import Foundation

/// Decides whether a harness permission request looks DESTRUCTIVE — the kind
/// of action a single misheard word or stray button press must never approve
/// (issue #47): deleting files, rewriting git history, force-pushing,
/// dropping databases, formatting disks. Destructive requests require a
/// second Approve press to confirm.
///
/// Deliberately conservative and pattern-based: a false positive costs one
/// extra button press; a false negative costs somebody's branch. Patterns are
/// matched case-insensitively against the tool kind, title, and detail.
enum DestructiveActionClassifier {

    /// ACP tool-call kinds that are destructive by definition.
    private static let destructiveKinds: Set<String> = ["delete"]

    /// Substring patterns (lowercased) that mark a command/title destructive.
    static let patterns: [String] = [
        "rm -rf", "rm -fr", "rm -r ", "sudo rm", "rmdir",
        "git reset --hard", "git clean -f", "git checkout -- ",
        "push --force", "push -f ", "--force-with-lease",
        "git branch -d", "git branch -D", "git rebase",
        "drop table", "drop database", "truncate table", "delete from ",
        "mkfs", "diskutil erase", "format c:",
        "shutdown", "reboot now", "killall ",
        "chmod -r 777", "chown -r ",
        "of=/dev/", "dd if=", ":(){",
        "terraform destroy", "kubectl delete", "docker system prune",
    ]

    static func isDestructive(kind: String, title: String, detail: String) -> Bool {
        if destructiveKinds.contains(kind.lowercased()) { return true }
        // Trailing space so end-anchored patterns ("push -f ") also match a
        // command that ENDS with the flag (bare "git push -f").
        let haystack = (title + " " + detail + " ").lowercased()
        return patterns.contains { haystack.contains($0.lowercased()) }
    }
}
