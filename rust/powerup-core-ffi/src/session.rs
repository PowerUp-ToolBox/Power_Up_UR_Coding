//! The session half of slice 2.3: the session state machine, the status
//! derivation, the destructive-action classifier and the setting cycles.
//!
//! As in `mapping`, the types are the uniffi faces of their `powerup-core`
//! twins with a `Core` prefix (DESIGN v2.12 A), converted with exhaustive
//! matches. `CoreSession` is owned by Swift (one per `AppState`) and never
//! calls back: each call returns the effects Swift runs, in order.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use powerup_core::harness::{destructive, HarnessKind};
use powerup_core::intent::Intent;
use powerup_core::session::cycles;
use powerup_core::session::{
    ConfigChange, HarnessSnapshot, HookEvent, HookKind, PendingPermission, PlacedPath, RemoteKey,
    SessionContext, SessionEffect, SessionMachine, SessionSettings, TranscriptKind,
};
use powerup_core::status::{self, AppStatus};

use crate::harness::{CoreHarnessConfiguration, CoreHarnessEvent, CoreHarnessState};
use crate::mapping::CoreIntent;
use crate::{contain, locked, CoreBridgeError};

/// Which adapter runs the built-in session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreHarnessKind {
    Claude,
    Acp,
}

impl From<HarnessKind> for CoreHarnessKind {
    fn from(kind: HarnessKind) -> Self {
        match kind {
            HarnessKind::Claude => CoreHarnessKind::Claude,
            HarnessKind::Acp => CoreHarnessKind::Acp,
        }
    }
}

impl From<CoreHarnessKind> for HarnessKind {
    fn from(kind: CoreHarnessKind) -> Self {
        match kind {
            CoreHarnessKind::Claude => HarnessKind::Claude,
            CoreHarnessKind::Acp => HarnessKind::Acp,
        }
    }
}

/// The config fields the session rules read, live per call (HK-165).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSessionSettings {
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
    pub session_ids_by_project: HashMap<String, String>,
    pub recent_project_dirs: Vec<String>,
    pub claude_path: Option<String>,
    pub remote_auto_submit: bool,
}

impl From<CoreSessionSettings> for SessionSettings {
    fn from(settings: CoreSessionSettings) -> Self {
        SessionSettings {
            harness_kind: settings.harness_kind,
            acp_agent: settings.acp_agent,
            acp_custom_command: settings.acp_custom_command,
            control_mode: settings.control_mode,
            model: settings.model,
            model_cycle: settings.model_cycle,
            effort: settings.effort,
            permission_mode: settings.permission_mode,
            project_dir: settings.project_dir,
            last_session_id: settings.last_session_id,
            session_ids_by_project: settings.session_ids_by_project.into_iter().collect(),
            recent_project_dirs: settings.recent_project_dirs,
            claude_path: settings.claude_path,
            remote_auto_submit: settings.remote_auto_submit,
        }
    }
}

/// One adapter as the platform sees it at the moment of the call.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHarnessSnapshot {
    pub state: CoreHarnessState,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    pub supports_effort: bool,
}

impl From<CoreHarnessSnapshot> for HarnessSnapshot {
    fn from(snapshot: CoreHarnessSnapshot) -> Self {
        HarnessSnapshot {
            state: snapshot.state.into(),
            session_id: snapshot.session_id,
            model_name: snapshot.model_name,
            supports_effort: snapshot.supports_effort,
        }
    }
}

/// Everything one session call reads.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSessionContext {
    pub settings: CoreSessionSettings,
    pub claude: CoreHarnessSnapshot,
    pub acp: Option<CoreHarnessSnapshot>,
    pub acp_agent_command: Option<Vec<String>>,
    /// Seconds since the platform's reference date.
    pub now: f64,
}

impl From<CoreSessionContext> for SessionContext {
    fn from(context: CoreSessionContext) -> Self {
        SessionContext {
            settings: context.settings.into(),
            claude: context.claude.into(),
            acp: context.acp.map(Into::into),
            acp_agent_command: context.acp_agent_command,
            now: context.now,
        }
    }
}

/// A path as the platform placed it on its filesystem (HK-398).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CorePlacedPath {
    pub components: Vec<String>,
    pub standardized: String,
    pub name: String,
}

impl From<CorePlacedPath> for PlacedPath {
    fn from(path: CorePlacedPath) -> Self {
        PlacedPath {
            components: path.components,
            standardized: path.standardized,
            name: path.name,
        }
    }
}

/// Which Claude Code hook fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreHookKind {
    UserPromptSubmit,
    PostToolUse,
    Notification,
    Stop,
    SessionEnd,
}

impl From<CoreHookKind> for HookKind {
    fn from(kind: CoreHookKind) -> Self {
        match kind {
            CoreHookKind::UserPromptSubmit => HookKind::UserPromptSubmit,
            CoreHookKind::PostToolUse => HookKind::PostToolUse,
            CoreHookKind::Notification => HookKind::Notification,
            CoreHookKind::Stop => HookKind::Stop,
            CoreHookKind::SessionEnd => HookKind::SessionEnd,
        }
    }
}

/// One Claude Code hook as the remote listener delivers it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHookEvent {
    pub kind: CoreHookKind,
    pub text: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
    /// `cwd` as the platform placed it; none when `cwd` is absent or empty.
    pub cwd_place: Option<CorePlacedPath>,
}

impl From<CoreHookEvent> for HookEvent {
    fn from(hook: CoreHookEvent) -> Self {
        HookEvent {
            kind: hook.kind.into(),
            text: hook.text,
            session_id: hook.session_id,
            cwd: hook.cwd,
            cwd_place: hook.cwd_place.map(Into::into),
        }
    }
}

/// The transcript entry kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreTranscriptKind {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

impl From<TranscriptKind> for CoreTranscriptKind {
    fn from(kind: TranscriptKind) -> Self {
        match kind {
            TranscriptKind::User => CoreTranscriptKind::User,
            TranscriptKind::Assistant => CoreTranscriptKind::Assistant,
            TranscriptKind::Tool => CoreTranscriptKind::Tool,
            TranscriptKind::System => CoreTranscriptKind::System,
            TranscriptKind::Error => CoreTranscriptKind::Error,
        }
    }
}

/// A key remote mode presses in the remote session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreRemoteKey {
    Enter,
    Escape,
    ShiftTab,
}

impl From<RemoteKey> for CoreRemoteKey {
    fn from(key: RemoteKey) -> Self {
        match key {
            RemoteKey::Enter => CoreRemoteKey::Enter,
            RemoteKey::Escape => CoreRemoteKey::Escape,
            RemoteKey::ShiftTab => CoreRemoteKey::ShiftTab,
        }
    }
}

/// The permission request waiting for an answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CorePendingPermission {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub is_destructive: bool,
    pub armed: bool,
}

impl From<PendingPermission> for CorePendingPermission {
    fn from(pending: PendingPermission) -> Self {
        CorePendingPermission {
            id: pending.id,
            name: pending.name,
            detail: pending.detail,
            is_destructive: pending.is_destructive,
            armed: pending.armed,
        }
    }
}

/// One config write.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreConfigChange {
    Model {
        value: String,
    },
    Effort {
        value: String,
    },
    PermissionMode {
        value: String,
    },
    ControlMode {
        value: String,
    },
    ProjectDir {
        path: String,
    },
    LastSessionId {
        session_id: Option<String>,
    },
    /// None removes the folder's entry.
    ProjectSessionId {
        project_dir: String,
        session_id: Option<String>,
    },
    RecentProjectDirs {
        paths: Vec<String>,
    },
}

impl From<ConfigChange> for CoreConfigChange {
    fn from(change: ConfigChange) -> Self {
        match change {
            ConfigChange::Model(value) => CoreConfigChange::Model { value },
            ConfigChange::Effort(value) => CoreConfigChange::Effort { value },
            ConfigChange::PermissionMode(value) => CoreConfigChange::PermissionMode { value },
            ConfigChange::ControlMode(value) => CoreConfigChange::ControlMode { value },
            ConfigChange::ProjectDir(path) => CoreConfigChange::ProjectDir { path },
            ConfigChange::LastSessionId(session_id) => {
                CoreConfigChange::LastSessionId { session_id }
            }
            ConfigChange::ProjectSessionId {
                project_dir,
                session_id,
            } => CoreConfigChange::ProjectSessionId {
                project_dir,
                session_id,
            },
            ConfigChange::RecentProjectDirs(paths) => CoreConfigChange::RecentProjectDirs { paths },
        }
    }
}

/// What the session asks the platform to do, case for case with
/// `powerup_core::session::SessionEffect`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreSessionEffect {
    StartHarness {
        harness: CoreHarnessKind,
        configuration: CoreHarnessConfiguration,
    },
    SendToHarness {
        harness: CoreHarnessKind,
        text: String,
    },
    InterruptHarness {
        harness: CoreHarnessKind,
    },
    SetHarnessModel {
        harness: CoreHarnessKind,
        model: String,
    },
    SetHarnessPermissionMode {
        harness: CoreHarnessKind,
        mode: String,
    },
    AnswerPermission {
        harness: CoreHarnessKind,
        id: String,
        allow: bool,
    },
    StopHarness {
        harness: CoreHarnessKind,
    },
    ChangeConfig {
        change: CoreConfigChange,
    },
    AppendTranscript {
        kind: CoreTranscriptKind,
        text: String,
    },
    ShowProjectTranscript {
        project_dir: String,
        restore_history: bool,
    },
    AppendLiveReply {
        text: String,
    },
    ClearLiveReply,
    SetLastReply {
        text: String,
    },
    PendingPermissionChanged {
        permission: Option<CorePendingPermission>,
    },
    RemoteTurnActiveChanged {
        active: bool,
    },
    RemoteFocusChanged {
        session_id: Option<String>,
    },
    Haptic {
        intensity: f32,
        duration: f64,
    },
    ErrorHaptic,
    Announce {
        phrase: String,
    },
    SpeakReply {
        text: String,
    },
    CancelSummary,
    StopSpeaking,
    InjectText {
        text: String,
        submit: bool,
    },
    InjectKey {
        key: CoreRemoteKey,
    },
    RefreshRemoteStatus,
    ScheduleRemoteTurnCheck {
        after_seconds: f64,
    },
    DeferEffortRestart,
    UpdateStatus,
}

impl From<SessionEffect> for CoreSessionEffect {
    fn from(effect: SessionEffect) -> Self {
        match effect {
            SessionEffect::StartHarness {
                harness,
                configuration,
            } => CoreSessionEffect::StartHarness {
                harness: harness.into(),
                configuration: configuration.into(),
            },
            SessionEffect::SendToHarness { harness, text } => CoreSessionEffect::SendToHarness {
                harness: harness.into(),
                text,
            },
            SessionEffect::InterruptHarness { harness } => CoreSessionEffect::InterruptHarness {
                harness: harness.into(),
            },
            SessionEffect::SetHarnessModel { harness, model } => {
                CoreSessionEffect::SetHarnessModel {
                    harness: harness.into(),
                    model,
                }
            }
            SessionEffect::SetHarnessPermissionMode { harness, mode } => {
                CoreSessionEffect::SetHarnessPermissionMode {
                    harness: harness.into(),
                    mode,
                }
            }
            SessionEffect::AnswerPermission { harness, id, allow } => {
                CoreSessionEffect::AnswerPermission {
                    harness: harness.into(),
                    id,
                    allow,
                }
            }
            SessionEffect::StopHarness { harness } => CoreSessionEffect::StopHarness {
                harness: harness.into(),
            },
            SessionEffect::ChangeConfig(change) => CoreSessionEffect::ChangeConfig {
                change: change.into(),
            },
            SessionEffect::AppendTranscript { kind, text } => CoreSessionEffect::AppendTranscript {
                kind: kind.into(),
                text,
            },
            SessionEffect::ShowProjectTranscript {
                project_dir,
                restore_history,
            } => CoreSessionEffect::ShowProjectTranscript {
                project_dir,
                restore_history,
            },
            SessionEffect::AppendLiveReply(text) => CoreSessionEffect::AppendLiveReply { text },
            SessionEffect::ClearLiveReply => CoreSessionEffect::ClearLiveReply,
            SessionEffect::SetLastReply(text) => CoreSessionEffect::SetLastReply { text },
            SessionEffect::PendingPermissionChanged(permission) => {
                CoreSessionEffect::PendingPermissionChanged {
                    permission: permission.map(Into::into),
                }
            }
            SessionEffect::RemoteTurnActiveChanged(active) => {
                CoreSessionEffect::RemoteTurnActiveChanged { active }
            }
            SessionEffect::RemoteFocusChanged(session_id) => {
                CoreSessionEffect::RemoteFocusChanged { session_id }
            }
            SessionEffect::Haptic {
                intensity,
                duration,
            } => CoreSessionEffect::Haptic {
                intensity,
                duration,
            },
            SessionEffect::ErrorHaptic => CoreSessionEffect::ErrorHaptic,
            SessionEffect::Announce(phrase) => CoreSessionEffect::Announce { phrase },
            SessionEffect::SpeakReply(text) => CoreSessionEffect::SpeakReply { text },
            SessionEffect::CancelSummary => CoreSessionEffect::CancelSummary,
            SessionEffect::StopSpeaking => CoreSessionEffect::StopSpeaking,
            SessionEffect::InjectText { text, submit } => {
                CoreSessionEffect::InjectText { text, submit }
            }
            SessionEffect::InjectKey(key) => CoreSessionEffect::InjectKey { key: key.into() },
            SessionEffect::RefreshRemoteStatus => CoreSessionEffect::RefreshRemoteStatus,
            SessionEffect::ScheduleRemoteTurnCheck { after_seconds } => {
                CoreSessionEffect::ScheduleRemoteTurnCheck { after_seconds }
            }
            SessionEffect::DeferEffortRestart => CoreSessionEffect::DeferEffortRestart,
            SessionEffect::UpdateStatus => CoreSessionEffect::UpdateStatus,
        }
    }
}

/// What the pill and the light bar show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreAppStatus {
    NoController,
    Idle,
    Listening,
    Thinking,
    Speaking,
}

impl From<AppStatus> for CoreAppStatus {
    fn from(status: AppStatus) -> Self {
        match status {
            AppStatus::NoController => CoreAppStatus::NoController,
            AppStatus::Idle => CoreAppStatus::Idle,
            AppStatus::Listening => CoreAppStatus::Listening,
            AppStatus::Thinking => CoreAppStatus::Thinking,
            AppStatus::Speaking => CoreAppStatus::Speaking,
        }
    }
}

/// AppState's session rules (`session::SessionMachine`). Swift creates one
/// per `AppState`, after the launch bookkeeping is seeded, and calls it on
/// the main actor; the lock only keeps the object sound. Every call
/// returns the effects Swift runs in order; an effect that makes an
/// adapter report an event at once re-enters with a fresh context, which
/// is safe because each call has returned before its effects run.
#[derive(Debug, uniffi::Object)]
pub struct CoreSession {
    machine: Mutex<SessionMachine>,
}

impl CoreSession {
    fn run(
        &self,
        context: CoreSessionContext,
        call: impl FnOnce(&mut SessionMachine, &SessionContext) -> Vec<SessionEffect>,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        contain(|| {
            let context = SessionContext::from(context);
            let effects = call(&mut locked(&self.machine), &context);
            Ok(effects.into_iter().map(Into::into).collect())
        })
    }
}

#[uniffi::export]
impl CoreSession {
    /// A machine that adopts the stored control mode and harness selection
    /// as its baselines without acting on them (HK-166).
    #[uniffi::constructor]
    pub fn new(initial: CoreSessionSettings) -> Result<Arc<Self>, CoreBridgeError> {
        contain(|| {
            Ok(Arc::new(CoreSession {
                machine: Mutex::new(SessionMachine::new(&initial.into())),
            }))
        })
    }

    pub fn start_session_if_needed(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::start_session_if_needed)
    }

    pub fn new_session(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::new_session)
    }

    pub fn send_user_text(
        &self,
        context: CoreSessionContext,
        text: String,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| machine.send_user_text(ctx, &text))
    }

    pub fn interrupt(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::interrupt)
    }

    pub fn answer_pending_permission(
        &self,
        context: CoreSessionContext,
        allow: bool,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| {
            machine.answer_pending_permission(ctx, allow)
        })
    }

    pub fn adopt_project(
        &self,
        context: CoreSessionContext,
        path: String,
        move_to_front: bool,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| {
            machine.adopt_project(ctx, &path, move_to_front)
        })
    }

    pub fn switch_project(
        &self,
        context: CoreSessionContext,
        path: String,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| machine.switch_project(ctx, &path))
    }

    /// `existing_recents`: the recents, in order, that still exist on disk.
    pub fn cycle_project(
        &self,
        context: CoreSessionContext,
        existing_recents: Vec<String>,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| {
            machine.cycle_project(ctx, &existing_recents)
        })
    }

    pub fn handle_intent(
        &self,
        context: CoreSessionContext,
        intent: CoreIntent,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        let intent = Intent::from(intent);
        self.run(context, |machine, ctx| machine.handle_intent(ctx, &intent))
    }

    /// An adapter's event; `from` is the adapter that reported it.
    pub fn harness_event(
        &self,
        context: CoreSessionContext,
        from: CoreHarnessKind,
        event: CoreHarnessEvent,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, |machine, ctx| {
            machine.harness_event(ctx, from.into(), event.into())
        })
    }

    /// A Claude Code hook; `project_place` is the project folder as the
    /// platform placed it, none when no folder is chosen.
    pub fn hook_event(
        &self,
        context: CoreSessionContext,
        hook: CoreHookEvent,
        project_place: Option<CorePlacedPath>,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        let hook = HookEvent::from(hook);
        let project = project_place.map(PlacedPath::from);
        self.run(context, |machine, ctx| {
            machine.hook_event(ctx, &hook, project.as_ref())
        })
    }

    pub fn remote_turn_check(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::remote_turn_check)
    }

    pub fn deferred_effort_restart(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::deferred_effort_restart)
    }

    pub fn sync_settings(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::sync_settings)
    }

    pub fn send_refused(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::send_refused)
    }

    pub fn shutdown(
        &self,
        context: CoreSessionContext,
    ) -> Result<Vec<CoreSessionEffect>, CoreBridgeError> {
        self.run(context, SessionMachine::shutdown)
    }

    pub fn pending_permission(&self) -> Result<Option<CorePendingPermission>, CoreBridgeError> {
        contain(|| {
            Ok(locked(&self.machine)
                .pending_permission()
                .cloned()
                .map(Into::into))
        })
    }

    pub fn remote_turn_active(&self) -> Result<bool, CoreBridgeError> {
        contain(|| Ok(locked(&self.machine).remote_turn_active()))
    }

    pub fn remote_focus(&self) -> Result<Option<String>, CoreBridgeError> {
        contain(|| Ok(locked(&self.machine).remote_focus().map(str::to_owned)))
    }

    pub fn remote_focus_label(&self) -> Result<Option<String>, CoreBridgeError> {
        contain(|| Ok(locked(&self.machine).remote_focus_label()))
    }
}

/// The status precedence (`status::derived_status`, HK-121).
#[uniffi::export]
pub fn derived_status(
    controller_connected: bool,
    is_ptt_active: bool,
    is_speaking: bool,
    is_working: bool,
) -> Result<CoreAppStatus, CoreBridgeError> {
    contain(|| {
        Ok(
            status::derived_status(controller_connected, is_ptt_active, is_speaking, is_working)
                .into(),
        )
    })
}

/// The working input of the status (`status::derived_is_working`, HK-120).
#[uniffi::export]
pub fn derived_is_working(
    harness_state: CoreHarnessState,
    is_remote_mode: bool,
    remote_turn_active: bool,
) -> Result<bool, CoreBridgeError> {
    contain(|| {
        Ok(status::derived_is_working(
            harness_state.into(),
            is_remote_mode,
            remote_turn_active,
        ))
    })
}

/// The remote turn table without its expired entries (HK-109).
#[uniffi::export]
pub fn live_remote_turns(
    turns: HashMap<String, f64>,
    now: f64,
    expiry: f64,
) -> Result<HashMap<String, f64>, CoreBridgeError> {
    contain(|| {
        let turns: BTreeMap<String, f64> = turns.into_iter().collect();
        Ok(status::live_remote_turns(&turns, now, expiry)
            .into_iter()
            .collect())
    })
}

/// Whether a remote turn lights the bar (DESIGN v2.2 B).
#[uniffi::export]
pub fn remote_turn_is_active(
    turns: HashMap<String, f64>,
    focus: Option<String>,
) -> Result<bool, CoreBridgeError> {
    contain(|| {
        let turns: BTreeMap<String, f64> = turns.into_iter().collect();
        Ok(status::remote_turn_is_active(&turns, focus.as_deref()))
    })
}

/// How long a remote turn lives without a sign of life.
#[uniffi::export]
pub fn remote_turn_expiry_seconds() -> Result<f64, CoreBridgeError> {
    contain(|| Ok(status::REMOTE_TURN_EXPIRY_SECONDS))
}

/// The model chip (HK-088).
#[uniffi::export]
pub fn model_chip_label(
    configured: String,
    reported: Option<String>,
) -> Result<String, CoreBridgeError> {
    contain(|| Ok(status::model_chip_label(&configured, reported.as_deref())))
}

/// Whether a permission request needs a second Approve (HK-093..097).
#[uniffi::export]
pub fn is_destructive(
    kind: String,
    title: String,
    detail: String,
) -> Result<bool, CoreBridgeError> {
    contain(|| Ok(destructive::is_destructive(&kind, &title, &detail)))
}

/// The substrings that make a request destructive, in the core's order;
/// the Swift suite counts its fixture cases against them.
#[uniffi::export]
pub fn destructive_patterns() -> Result<Vec<String>, CoreBridgeError> {
    contain(|| Ok(owned(&destructive::PATTERNS)))
}

fn owned(values: &[&str]) -> Vec<String> {
    values.iter().map(|&value| value.to_owned()).collect()
}

/// The effort cycle (HK-009).
#[uniffi::export]
pub fn effort_cycle() -> Result<Vec<String>, CoreBridgeError> {
    contain(|| Ok(owned(&cycles::EFFORT_CYCLE)))
}

/// The permission-mode cycle (HK-008).
#[uniffi::export]
pub fn permission_mode_cycle() -> Result<Vec<String>, CoreBridgeError> {
    contain(|| Ok(owned(&cycles::PERMISSION_MODE_CYCLE)))
}

/// The model cycle when the user's own is empty.
#[uniffi::export]
pub fn default_model_cycle() -> Result<Vec<String>, CoreBridgeError> {
    contain(|| Ok(owned(&cycles::DEFAULT_MODEL_CYCLE)))
}

/// The name an effort value is shown and spoken by.
#[uniffi::export]
pub fn effort_display_name(effort: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(cycles::effort_display_name(&effort)))
}

/// The name an ACP agent setting is shown by.
#[uniffi::export]
pub fn acp_agent_display_name(agent: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(cycles::acp_agent_display_name(&agent)))
}

/// The stored control mode read at runtime: only "remote" is remote mode
/// (HK-156).
#[uniffi::export]
pub fn is_remote_mode(control_mode: String) -> Result<bool, CoreBridgeError> {
    contain(|| Ok(cycles::is_remote_mode(&control_mode)))
}

/// The stored harness kind read at runtime: anything but "acp" is the
/// built-in Claude harness (HK-156).
#[uniffi::export]
pub fn harness_kind_from_setting(raw: String) -> Result<CoreHarnessKind, CoreBridgeError> {
    contain(|| Ok(HarnessKind::from_setting(&raw).into()))
}

#[cfg(test)]
mod tests {
    use powerup_core::harness::HarnessConfiguration;

    use super::*;

    /// The way back, for the round trip only: the platform never hands the
    /// core an effect.
    fn back(effect: CoreSessionEffect) -> SessionEffect {
        let kind = HarnessKind::from;
        match effect {
            CoreSessionEffect::StartHarness {
                harness,
                configuration,
            } => SessionEffect::StartHarness {
                harness: kind(harness),
                configuration: configuration.into(),
            },
            CoreSessionEffect::SendToHarness { harness, text } => SessionEffect::SendToHarness {
                harness: kind(harness),
                text,
            },
            CoreSessionEffect::InterruptHarness { harness } => SessionEffect::InterruptHarness {
                harness: kind(harness),
            },
            CoreSessionEffect::SetHarnessModel { harness, model } => {
                SessionEffect::SetHarnessModel {
                    harness: kind(harness),
                    model,
                }
            }
            CoreSessionEffect::SetHarnessPermissionMode { harness, mode } => {
                SessionEffect::SetHarnessPermissionMode {
                    harness: kind(harness),
                    mode,
                }
            }
            CoreSessionEffect::AnswerPermission { harness, id, allow } => {
                SessionEffect::AnswerPermission {
                    harness: kind(harness),
                    id,
                    allow,
                }
            }
            CoreSessionEffect::StopHarness { harness } => SessionEffect::StopHarness {
                harness: kind(harness),
            },
            CoreSessionEffect::ChangeConfig { change } => {
                SessionEffect::ChangeConfig(match change {
                    CoreConfigChange::Model { value } => ConfigChange::Model(value),
                    CoreConfigChange::Effort { value } => ConfigChange::Effort(value),
                    CoreConfigChange::PermissionMode { value } => {
                        ConfigChange::PermissionMode(value)
                    }
                    CoreConfigChange::ControlMode { value } => ConfigChange::ControlMode(value),
                    CoreConfigChange::ProjectDir { path } => ConfigChange::ProjectDir(path),
                    CoreConfigChange::LastSessionId { session_id } => {
                        ConfigChange::LastSessionId(session_id)
                    }
                    CoreConfigChange::ProjectSessionId {
                        project_dir,
                        session_id,
                    } => ConfigChange::ProjectSessionId {
                        project_dir,
                        session_id,
                    },
                    CoreConfigChange::RecentProjectDirs { paths } => {
                        ConfigChange::RecentProjectDirs(paths)
                    }
                })
            }
            CoreSessionEffect::AppendTranscript { kind, text } => SessionEffect::AppendTranscript {
                kind: match kind {
                    CoreTranscriptKind::User => TranscriptKind::User,
                    CoreTranscriptKind::Assistant => TranscriptKind::Assistant,
                    CoreTranscriptKind::Tool => TranscriptKind::Tool,
                    CoreTranscriptKind::System => TranscriptKind::System,
                    CoreTranscriptKind::Error => TranscriptKind::Error,
                },
                text,
            },
            CoreSessionEffect::ShowProjectTranscript {
                project_dir,
                restore_history,
            } => SessionEffect::ShowProjectTranscript {
                project_dir,
                restore_history,
            },
            CoreSessionEffect::AppendLiveReply { text } => SessionEffect::AppendLiveReply(text),
            CoreSessionEffect::ClearLiveReply => SessionEffect::ClearLiveReply,
            CoreSessionEffect::SetLastReply { text } => SessionEffect::SetLastReply(text),
            CoreSessionEffect::PendingPermissionChanged { permission } => {
                SessionEffect::PendingPermissionChanged(permission.map(|p| PendingPermission {
                    id: p.id,
                    name: p.name,
                    detail: p.detail,
                    is_destructive: p.is_destructive,
                    armed: p.armed,
                }))
            }
            CoreSessionEffect::RemoteTurnActiveChanged { active } => {
                SessionEffect::RemoteTurnActiveChanged(active)
            }
            CoreSessionEffect::RemoteFocusChanged { session_id } => {
                SessionEffect::RemoteFocusChanged(session_id)
            }
            CoreSessionEffect::Haptic {
                intensity,
                duration,
            } => SessionEffect::Haptic {
                intensity,
                duration,
            },
            CoreSessionEffect::ErrorHaptic => SessionEffect::ErrorHaptic,
            CoreSessionEffect::Announce { phrase } => SessionEffect::Announce(phrase),
            CoreSessionEffect::SpeakReply { text } => SessionEffect::SpeakReply(text),
            CoreSessionEffect::CancelSummary => SessionEffect::CancelSummary,
            CoreSessionEffect::StopSpeaking => SessionEffect::StopSpeaking,
            CoreSessionEffect::InjectText { text, submit } => {
                SessionEffect::InjectText { text, submit }
            }
            CoreSessionEffect::InjectKey { key } => SessionEffect::InjectKey(match key {
                CoreRemoteKey::Enter => RemoteKey::Enter,
                CoreRemoteKey::Escape => RemoteKey::Escape,
                CoreRemoteKey::ShiftTab => RemoteKey::ShiftTab,
            }),
            CoreSessionEffect::RefreshRemoteStatus => SessionEffect::RefreshRemoteStatus,
            CoreSessionEffect::ScheduleRemoteTurnCheck { after_seconds } => {
                SessionEffect::ScheduleRemoteTurnCheck { after_seconds }
            }
            CoreSessionEffect::DeferEffortRestart => SessionEffect::DeferEffortRestart,
            CoreSessionEffect::UpdateStatus => SessionEffect::UpdateStatus,
        }
    }

    #[test]
    fn every_session_effect_converts() {
        let configuration = HarnessConfiguration {
            project_dir: "/work/app".to_string(),
            model: "sonnet".to_string(),
            permission_mode: "plan".to_string(),
            effort: "max".to_string(),
            resume_session_id: Some("s-1".to_string()),
            binary_path_override: Some("/bin/claude".to_string()),
            agent_command: Some(vec!["opencode".to_string(), "acp".to_string()]),
        };
        let pending = PendingPermission {
            id: "p1".to_string(),
            name: "Bash".to_string(),
            detail: "rm -rf build".to_string(),
            is_destructive: true,
            armed: true,
        };
        let mut every = vec![
            SessionEffect::StartHarness {
                harness: HarnessKind::Claude,
                configuration,
            },
            SessionEffect::SendToHarness {
                harness: HarnessKind::Acp,
                text: "Hi".to_string(),
            },
            SessionEffect::InterruptHarness {
                harness: HarnessKind::Claude,
            },
            SessionEffect::SetHarnessModel {
                harness: HarnessKind::Claude,
                model: "opus".to_string(),
            },
            SessionEffect::SetHarnessPermissionMode {
                harness: HarnessKind::Acp,
                mode: "plan".to_string(),
            },
            SessionEffect::AnswerPermission {
                harness: HarnessKind::Acp,
                id: "p1".to_string(),
                allow: false,
            },
            SessionEffect::StopHarness {
                harness: HarnessKind::Acp,
            },
            SessionEffect::ShowProjectTranscript {
                project_dir: "/work/app".to_string(),
                restore_history: true,
            },
            SessionEffect::AppendLiveReply("Hel".to_string()),
            SessionEffect::ClearLiveReply,
            SessionEffect::SetLastReply("Hello".to_string()),
            SessionEffect::PendingPermissionChanged(Some(pending)),
            SessionEffect::PendingPermissionChanged(None),
            SessionEffect::RemoteTurnActiveChanged(true),
            SessionEffect::RemoteFocusChanged(Some("s-2".to_string())),
            SessionEffect::RemoteFocusChanged(None),
            SessionEffect::Haptic {
                intensity: 0.5,
                duration: 0.05,
            },
            SessionEffect::ErrorHaptic,
            SessionEffect::Announce("Sonnet".to_string()),
            SessionEffect::SpeakReply("Hello".to_string()),
            SessionEffect::CancelSummary,
            SessionEffect::StopSpeaking,
            SessionEffect::InjectText {
                text: "/clear".to_string(),
                submit: true,
            },
            SessionEffect::RefreshRemoteStatus,
            SessionEffect::ScheduleRemoteTurnCheck {
                after_seconds: 901.0,
            },
            SessionEffect::DeferEffortRestart,
            SessionEffect::UpdateStatus,
        ];
        every.extend(
            [
                ConfigChange::Model("sonnet".to_string()),
                ConfigChange::Effort("low".to_string()),
                ConfigChange::PermissionMode("plan".to_string()),
                ConfigChange::ControlMode("remote".to_string()),
                ConfigChange::ProjectDir("/work/app".to_string()),
                ConfigChange::LastSessionId(None),
                ConfigChange::ProjectSessionId {
                    project_dir: "/work/app".to_string(),
                    session_id: Some("s-1".to_string()),
                },
                ConfigChange::RecentProjectDirs(vec!["/work/app".to_string()]),
            ]
            .map(SessionEffect::ChangeConfig),
        );
        every.extend(
            [
                TranscriptKind::User,
                TranscriptKind::Assistant,
                TranscriptKind::Tool,
                TranscriptKind::System,
                TranscriptKind::Error,
            ]
            .map(|kind| SessionEffect::AppendTranscript {
                kind,
                text: "entry".to_string(),
            }),
        );
        every.extend(
            [RemoteKey::Enter, RemoteKey::Escape, RemoteKey::ShiftTab]
                .map(SessionEffect::InjectKey),
        );
        for effect in every {
            assert_eq!(back(CoreSessionEffect::from(effect.clone())), effect);
        }
    }

    fn settings() -> CoreSessionSettings {
        CoreSessionSettings {
            harness_kind: "claude".to_string(),
            acp_agent: "opencode".to_string(),
            acp_custom_command: String::new(),
            control_mode: "builtin".to_string(),
            model: "default".to_string(),
            model_cycle: Vec::new(),
            effort: "default".to_string(),
            permission_mode: "acceptEdits".to_string(),
            project_dir: Some("/work/app".to_string()),
            last_session_id: None,
            session_ids_by_project: HashMap::from([("/work/app".to_string(), "s-1".to_string())]),
            recent_project_dirs: vec!["/work/app".to_string()],
            claude_path: None,
            remote_auto_submit: true,
        }
    }

    fn context() -> CoreSessionContext {
        CoreSessionContext {
            settings: settings(),
            claude: CoreHarnessSnapshot {
                state: CoreHarnessState::Stopped,
                session_id: None,
                model_name: None,
                supports_effort: true,
            },
            acp: None,
            acp_agent_command: None,
            now: 800_000_000.0,
        }
    }

    #[test]
    fn the_session_object_runs_the_core_rules() {
        let session = CoreSession::new(settings()).unwrap();
        let effects = session.start_session_if_needed(context()).unwrap();
        assert!(
            effects.iter().any(|effect| matches!(
                effect,
                CoreSessionEffect::StartHarness {
                    harness: CoreHarnessKind::Claude,
                    configuration: CoreHarnessConfiguration { resume_session_id: Some(id), .. },
                } if id == "s-1"
            )),
            "{effects:?}"
        );
        assert_eq!(session.pending_permission(), Ok(None));
        assert_eq!(session.remote_turn_active(), Ok(false));
        assert_eq!(session.remote_focus(), Ok(None));
        assert_eq!(session.remote_focus_label(), Ok(None));
        // An event from the adapter that is not selected is dropped.
        assert_eq!(
            session.harness_event(
                context(),
                CoreHarnessKind::Acp,
                CoreHarnessEvent::Reply {
                    text: "late".to_string()
                }
            ),
            Ok(Vec::new())
        );
    }

    #[test]
    fn the_status_and_cycle_functions_answer_like_the_core() {
        assert_eq!(
            derived_status(false, false, false, true),
            Ok(CoreAppStatus::Thinking)
        );
        assert_eq!(
            derived_is_working(CoreHarnessState::Ready, true, true),
            Ok(true)
        );
        let turns = HashMap::from([("old".to_string(), 0.0), ("new".to_string(), 950.0)]);
        assert_eq!(
            live_remote_turns(turns.clone(), 1000.0, 900.0),
            Ok(HashMap::from([("new".to_string(), 950.0)]))
        );
        assert_eq!(
            remote_turn_is_active(turns, Some("gone".to_string())),
            Ok(false)
        );
        assert_eq!(remote_turn_expiry_seconds(), Ok(900.0));
        assert_eq!(
            model_chip_label("default".to_string(), Some("claude-opus".to_string())),
            Ok("claude-opus".to_string())
        );
        assert_eq!(
            is_destructive(String::new(), "Bash".to_string(), "git push -f".to_string()),
            Ok(true)
        );
        assert_eq!(
            destructive_patterns().unwrap().len(),
            destructive::PATTERNS.len()
        );
        assert_eq!(effort_cycle().unwrap().last(), Some(&"max".to_string()));
        assert_eq!(permission_mode_cycle().unwrap().len(), 3);
        assert_eq!(default_model_cycle().unwrap()[0], "sonnet");
        assert_eq!(
            effort_display_name("max".to_string()),
            Ok("Ultra".to_string())
        );
        assert_eq!(
            acp_agent_display_name("custom".to_string()),
            Ok("Custom command".to_string())
        );
        assert_eq!(is_remote_mode("Remote".to_string()), Ok(false));
        assert_eq!(
            harness_kind_from_setting("ACP".to_string()),
            Ok(CoreHarnessKind::Claude)
        );
    }
}
