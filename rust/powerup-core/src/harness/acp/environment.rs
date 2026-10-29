//! The variables removed from a spawned ACP agent's environment (HK-127).
//!
//! The Claude bridge refuses to run inside a Claude Code session (verified
//! live on 2026-08-27), and PowerUp is often started from one, so the
//! nesting markers must not reach the agent. The platform builds the
//! agent's environment from its own: it removes what this list names (an
//! exact name, or a name with one of the prefixes, compared as
//! [`is_scrubbed`] does) and adds its own install locations to PATH, which
//! is environment construction on that platform's paths and stays there
//! (HK-128). Windows compares variable names case-insensitively; slice 3.1
//! decides whether to scrub them case-insensitively there.

use crate::text;

/// Names removed exactly.
pub const SCRUBBED_NAMES: [&str; 2] = ["CLAUDECODE", "CLAUDE_PID"];

/// Every name with one of these prefixes is removed.
pub const SCRUBBED_PREFIXES: [&str; 1] = ["CLAUDE_CODE_"];

/// Whether the variable `name` is removed: an exact name, or a prefix
/// matched by whole clusters as Swift's `hasPrefix` matched it, so a
/// combining mark after `CLAUDE_CODE_` keeps the variable. Case-sensitive.
pub fn is_scrubbed(name: &str) -> bool {
    SCRUBBED_NAMES.contains(&name)
        || SCRUBBED_PREFIXES
            .iter()
            .any(|prefix| text::starts_with_clusters(name, prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The #154 acceptance criterion: the list is the Swift app's, exactly
    /// (ACPAdapter.agentEnvironment(from:) at dddf9c6). The Swift suite has
    /// the twin test once the bridge carries the list.
    #[test]
    fn the_scrub_list_is_the_swift_list() {
        assert_eq!(SCRUBBED_NAMES, ["CLAUDECODE", "CLAUDE_PID"]);
        assert_eq!(SCRUBBED_PREFIXES, ["CLAUDE_CODE_"]);
    }

    #[test]
    fn names_are_exact_and_prefixes_whole() {
        assert!(is_scrubbed("CLAUDECODE"));
        assert!(is_scrubbed("CLAUDE_CODE_SESSION_ID"));
        assert!(!is_scrubbed("CLAUDECODE_X"));
        assert!(!is_scrubbed("CLAUDE_CODE"));
        assert!(!is_scrubbed("CLAUDE_CODE_\u{301}X"));
        assert!(!is_scrubbed("claudecode"));
    }
}
