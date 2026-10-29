//! Harness adapters' platform-independent rules (spec #98). A harness is the
//! coding agent PowerUp drives; each adapter's wire rules live under its own
//! module, and the platform owns the process and its pipes. Every adapter
//! reads its stdout lines with the one Foundation-matching JSON reader
//! (`json`).

pub mod acp;
pub mod claude;
pub mod destructive;
pub(crate) mod json;

/// Which adapter runs the built-in session (Settings → General → Harness).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessKind {
    /// The built-in Claude Code adapter.
    Claude,
    /// An Agent Client Protocol agent.
    Acp,
}

impl HarnessKind {
    /// The stored setting read at runtime: any value other than "acp" is
    /// the built-in Claude harness, so a hand-edited or unknown kind can
    /// never leave PowerUp with no harness at all (HK-156).
    pub fn from_setting(raw: &str) -> HarnessKind {
        if raw == "acp" {
            HarnessKind::Acp
        } else {
            HarnessKind::Claude
        }
    }

    /// The stored spelling ("claude", "acp").
    pub fn name(self) -> &'static str {
        match self {
            HarnessKind::Claude => "claude",
            HarnessKind::Acp => "acp",
        }
    }
}

/// Lifecycle of a harness session (Swift's `HarnessState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessState {
    /// No process, or one that is shutting down.
    Stopped,
    /// Launched, waiting for the harness to report its session.
    Starting,
    /// A session is up and idle.
    Ready,
    /// A turn is in flight.
    Working,
}

/// Everything an adapter needs to start (or resume) a session. Fields a
/// harness has no use for are ignored by its adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessConfiguration {
    /// The project folder the harness runs in, as a path.
    pub project_dir: String,
    /// A harness-specific alias; `"default"` means the adapter's default.
    pub model: String,
    pub permission_mode: String,
    /// `"default"` means ask for none.
    pub effort: String,
    pub resume_session_id: Option<String>,
    /// The Settings path to the harness binary, for adapters that resolve
    /// their own.
    pub binary_path_override: Option<String>,
    /// For ACP adapters: the agent command line (executable and arguments).
    pub agent_command: Option<Vec<String>>,
}

/// The normalized event stream every harness adapter produces (DESIGN.md
/// v1.7, v2.2), case for case with Swift's `HarnessEvent`: the only
/// vocabulary the session consumes.
#[derive(Debug, Clone, PartialEq)]
pub enum HarnessEvent {
    SessionReady {
        session_id: String,
        model: String,
    },
    /// A streaming chunk of reply text.
    ReplyDelta(String),
    /// One complete assistant message.
    Reply(String),
    ToolUse {
        name: String,
        detail: String,
    },
    TurnCompleted {
        result_text: Option<String>,
        cost_usd: Option<f64>,
        is_error: bool,
        detail: String,
    },
    /// The answer to a control request (interrupt, set model, set
    /// permission mode): the subtype as `action`, and the value the request
    /// asked for.
    ControlResult {
        action: String,
        ok: bool,
        detail: String,
        value: Option<String>,
    },
    /// The harness asks the user to approve something; `kind` is its own
    /// tool category and feeds the destructive-action classifier (an empty
    /// or wrong kind only skips its "delete" rule, HK-091). Reserved for
    /// adapters that surface permission prompts (HK-092): ACP agents emit
    /// it, the Claude adapter never does, because Claude asks in its reply
    /// and Approve answers with the word Yes. Nothing on the Claude path may
    /// wait for one.
    PermissionRequest {
        id: String,
        name: String,
        kind: String,
        detail: String,
    },
    /// The harness wants attention outside a turn. Reserved like
    /// `PermissionRequest`: the Claude adapter never emits it.
    Notification(String),
    RuntimeError(String),
    Ended {
        exit_code: i32,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_acp_selects_the_acp_harness() {
        assert_eq!(HarnessKind::from_setting("acp"), HarnessKind::Acp);
        for raw in ["claude", "", "ACP", "x"] {
            assert_eq!(HarnessKind::from_setting(raw), HarnessKind::Claude, "{raw}");
        }
    }
}
