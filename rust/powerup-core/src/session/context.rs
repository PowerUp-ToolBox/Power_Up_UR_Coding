//! What the platform hands the session with every call: the settings as
//! they are right now, each adapter's state, and the time.

use std::collections::BTreeMap;

use crate::harness::HarnessState;

/// The config fields the session rules read. They are read live, per call
/// (HK-165): a Settings edit, a pad press and a hand-edited file all agree
/// at once, and nothing in the session caches them.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionSettings {
    pub harness_kind: String,
    pub acp_agent: String,
    pub acp_custom_command: String,
    pub control_mode: String,
    pub model: String,
    pub model_cycle: Vec<String>,
    pub effort: String,
    pub permission_mode: String,
    pub project_dir: Option<String>,
    pub last_session_id: Option<String>,
    /// Each project folder's own resumable session id.
    pub session_ids_by_project: BTreeMap<String, String>,
    pub recent_project_dirs: Vec<String>,
    /// The Settings path to the claude binary.
    pub claude_path: Option<String>,
    pub remote_auto_submit: bool,
}

/// One adapter as the platform sees it at the moment of the call.
#[derive(Debug, Clone, PartialEq)]
pub struct HarnessSnapshot {
    pub state: HarnessState,
    /// The session id the running harness owns.
    pub session_id: Option<String>,
    /// The model the harness last reported.
    pub model_name: Option<String>,
    /// The effort setting switches by restart and resume.
    pub supports_effort: bool,
}

impl HarnessSnapshot {
    /// An adapter that has not been created yet: stopped, owning nothing.
    pub fn stopped() -> HarnessSnapshot {
        HarnessSnapshot {
            state: HarnessState::Stopped,
            session_id: None,
            model_name: None,
            supports_effort: false,
        }
    }
}

/// Everything one session call reads.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionContext {
    pub settings: SessionSettings,
    /// The built-in Claude adapter.
    pub claude: HarnessSnapshot,
    /// The ACP adapter; `None` until the platform has created one (it is
    /// created lazily, the first time the ACP kind is used).
    pub acp: Option<HarnessSnapshot>,
    /// The ACP agent's command line, resolved by the platform (it looks
    /// for the agent's binary on disk). Filled only while the ACP kind is
    /// selected; `None` then means the agent's command was not found.
    pub acp_agent_command: Option<Vec<String>>,
    /// Seconds since the platform's reference date, from its clock.
    pub now: f64,
}

/// A path as the platform placed it on its filesystem (D7 of the slice
/// plan, ledger HK-398). The session never touches the filesystem: the
/// platform standardizes the path and resolves its symlinks, and the core
/// applies the rules to the result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlacedPath {
    /// The path's components after standardizing it and resolving its
    /// symlinks, the root first (`["/", "work", "app"]`).
    pub components: Vec<String>,
    /// The standardized path, symlinks left as they are.
    pub standardized: String,
    /// The last component of `standardized`.
    pub name: String,
}

/// Which Claude Code hook fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookKind {
    UserPromptSubmit,
    /// Fires on every tool call: the turn's heartbeat.
    PostToolUse,
    Notification,
    Stop,
    SessionEnd,
}

/// One Claude Code hook as the remote listener delivers it.
#[derive(Debug, Clone, PartialEq)]
pub struct HookEvent {
    pub kind: HookKind,
    /// The prompt, the reply, the message, the tool name or the end reason,
    /// by kind.
    pub text: Option<String>,
    pub session_id: Option<String>,
    /// The session's working directory as the hook reported it.
    pub cwd: Option<String>,
    /// `cwd` as the platform placed it; `None` when `cwd` is absent or
    /// empty.
    pub cwd_place: Option<PlacedPath>,
}
