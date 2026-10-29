//! Harness adapters' platform-independent rules (spec #98). A harness is the
//! coding agent PowerUp drives; each adapter's wire rules live under its own
//! module, and the platform owns the process and its pipes.

pub mod claude;

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
    /// tool category and feeds the destructive-action classifier.
    PermissionRequest {
        id: String,
        name: String,
        kind: String,
        detail: String,
    },
    /// The harness wants attention outside a turn.
    Notification(String),
    RuntimeError(String),
    Ended {
        exit_code: i32,
    },
}
