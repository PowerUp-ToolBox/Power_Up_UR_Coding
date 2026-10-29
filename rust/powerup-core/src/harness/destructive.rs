//! Whether a harness permission request is destructive (issue #47,
//! HK-093..097): the kind of action a misheard word or a stray press must
//! never approve. A destructive request takes a second Approve to confirm.
//!
//! Deliberately conservative and pattern-based: a false positive costs one
//! extra press, a false negative costs somebody's branch. Matching is pure
//! substring on purpose, so a path that merely contains a token
//! (`./rmdir-notes`) asks for the extra press too.

/// The tool kind an ACP agent reports for deleting, destructive by
/// definition. Compared lowercased, never trimmed.
const DESTRUCTIVE_KIND: &str = "delete";

/// The substring patterns, in the order the Swift list had them. Each is
/// lowercased before it is searched for, so "git branch -D" is a duplicate
/// of "git branch -d"; it stays so the list reads the same in both
/// languages. Trailing spaces are part of a pattern ("rm -r " is not
/// "rm -rf", "git checkout -- " is not "--theirs"). "> /dev/" was removed so
/// the "> /dev/null" idiom stays one press; raw-device writes are caught by
/// "of=/dev/" (HK-095). The over-matches ("git rebase" wholesale,
/// "--force-with-lease") and the spelling variants are deliberate: dropping
/// any of them reopens a false negative (HK-097).
pub const PATTERNS: [&str; 32] = [
    "rm -rf",
    "rm -fr",
    "rm -r ",
    "sudo rm",
    "rmdir",
    "git reset --hard",
    "git clean -f",
    "git checkout -- ",
    "push --force",
    "push -f ",
    "--force-with-lease",
    "git branch -d",
    "git branch -D",
    "git rebase",
    "drop table",
    "drop database",
    "truncate table",
    "delete from ",
    "mkfs",
    "diskutil erase",
    "format c:",
    "shutdown",
    "reboot now",
    "killall ",
    "chmod -r 777",
    "chown -r ",
    "of=/dev/",
    "dd if=",
    ":(){",
    "terraform destroy",
    "kubectl delete",
    "docker system prune",
];

/// The kind `"delete"` (lowercased) is always destructive. Otherwise the
/// haystack is `title + " " + detail + " "`, lowercased, and any pattern
/// inside it makes the request destructive. The trailing space lets an
/// end-anchored pattern ("push -f ") match a command that ends with the
/// flag (HK-094); the joining space means a pattern can span the title and
/// the detail, which errs to the safe side.
pub fn is_destructive(kind: &str, title: &str, detail: &str) -> bool {
    if kind.to_lowercase() == DESTRUCTIVE_KIND {
        return true;
    }
    let haystack = format!("{title} {detail} ").to_lowercase();
    PATTERNS
        .iter()
        .any(|pattern| haystack.contains(&pattern.to_lowercase()))
}
