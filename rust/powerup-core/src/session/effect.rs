//! The session's effects: what it asks the platform to do, named for what
//! happens, never for how a platform does it (CONTEXT.md, "Effect").

use crate::harness::{HarnessConfiguration, HarnessKind};

/// The transcript entry kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptKind {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

/// A key remote mode presses in the remote session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteKey {
    Enter,
    Escape,
    ShiftTab,
}

/// The permission request waiting for an answer (built-in mode only).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingPermission {
    pub id: String,
    pub name: String,
    pub detail: String,
    /// The classifier flagged it: two Approves are needed.
    pub is_destructive: bool,
    /// A first Approve came in; the next one confirms unless another
    /// intent comes first (HK-098).
    pub armed: bool,
}

/// One config write, in the order and under the conditions the session
/// rules make it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigChange {
    Model(String),
    Effort(String),
    PermissionMode(String),
    ControlMode(String),
    ProjectDir(String),
    LastSessionId(Option<String>),
    /// A project folder's own session id; `None` removes the entry.
    ProjectSessionId {
        project_dir: String,
        session_id: Option<String>,
    },
    RecentProjectDirs(Vec<String>),
}

/// What the session asks the platform to do. The platform carries the
/// effects out in order, each before the next; an effect that makes an
/// adapter report an event at once re-enters the session with a fresh
/// context, and that call's effects run before the rest.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEffect {
    /// Start (or resume) a session on that harness.
    StartHarness {
        harness: HarnessKind,
        configuration: HarnessConfiguration,
    },
    /// Send a user turn. The platform checks again when it runs it: if the
    /// harness has stopped meanwhile (its start failed at once), it calls
    /// `send_refused` instead.
    SendToHarness {
        harness: HarnessKind,
        text: String,
    },
    InterruptHarness {
        harness: HarnessKind,
    },
    SetHarnessModel {
        harness: HarnessKind,
        model: String,
    },
    SetHarnessPermissionMode {
        harness: HarnessKind,
        mode: String,
    },
    /// Answer a permission request by its id.
    AnswerPermission {
        harness: HarnessKind,
        id: String,
        allow: bool,
    },
    StopHarness {
        harness: HarnessKind,
    },
    ChangeConfig(ConfigChange),
    /// Append a transcript entry (the platform trims it and drops it when
    /// empty).
    AppendTranscript {
        kind: TranscriptKind,
        text: String,
    },
    /// Keep the transcript for this project folder from now on; with
    /// `restore_history`, replace the scrollback with that folder's stored
    /// history.
    ShowProjectTranscript {
        project_dir: String,
        restore_history: bool,
    },
    /// Streamed reply text, shown live until the full message arrives.
    AppendLiveReply(String),
    ClearLiveReply,
    /// The reply Replay Last Reply speaks.
    SetLastReply(String),
    /// The waiting permission request changed (sent only on a change).
    PendingPermissionChanged(Option<PendingPermission>),
    /// Whether a remote turn lights the working state (only on a change).
    RemoteTurnActiveChanged(bool),
    /// The focused remote session (only on a change).
    RemoteFocusChanged(Option<String>),
    Haptic {
        intensity: f32,
        duration: f64,
    },
    /// The two-buzz "that didn't work".
    ErrorHaptic,
    /// A short spoken confirmation, when spoken replies are on.
    Announce(String),
    /// Speak a reply (or its summary), when spoken replies are on.
    SpeakReply(String),
    /// A summary still being written belongs to a moment that is over.
    CancelSummary,
    StopSpeaking,
    /// Type text into the remote session, then press Enter when `submit`.
    InjectText {
        text: String,
        submit: bool,
    },
    InjectKey(RemoteKey),
    /// Re-read what the remote target offers (cmux availability).
    RefreshRemoteStatus,
    /// Call `remote_turn_check` after this many seconds.
    ScheduleRemoteTurnCheck {
        after_seconds: f64,
    },
    /// Call `deferred_effort_restart` once the current event delivery is
    /// over, so later events of the same batch reach the old session.
    DeferEffortRestart,
    /// Recompute the status pill and the light bar.
    UpdateStatus,
}
