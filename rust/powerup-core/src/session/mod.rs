//! The session state machine (spec #98, slice 2.3): AppState's session
//! rules, for every harness and for remote mode.
//!
//! The platform owns the machine (one per app window state), calls it on
//! one thread, and carries out what each call returns. Every call takes a
//! [`SessionContext`]: the settings as they are now, each adapter's state,
//! and the time. Nothing in here touches a process, a pipe, a file, a
//! speaker or a clock; the session decides and the platform acts.
//!
//! The effects ([`SessionEffect`]), in the glossary's words (CONTEXT.md):
//! - the **Harness**: start it (fresh or resuming a session id), send a
//!   prompt, interrupt the turn, switch its model or permission mode live,
//!   answer a permission request, stop it;
//! - the **config**: each setting the rules write, in the order they write
//!   it, including the stored and per-project session ids;
//! - the **transcript**: append an entry, switch to a project folder's
//!   history, the live reply text, the reply Replay speaks;
//! - published state: the pending permission request, the remote turn
//!   flag and the remote focus (each sent only when it changes);
//! - feedback: haptics, the error buzz, a spoken confirmation, a spoken
//!   reply, cancelling a summary, stopping speech;
//! - **remote mode**: type text or press a key in the remote session,
//!   refresh what the remote target offers;
//! - timing: a remote-turn expiry check after some seconds, the effort
//!   restart deferred past the current event delivery, and a status update.
//!
//! Within one call the machine works on a copy of the context and models
//! what its own harness commands do to the adapters at once, as both real
//! adapters do it synchronously: a start makes the adapter starting with
//! the resumed id as its session id and no model; a send makes it working;
//! a stop makes it stopped, and an ACP adapter also drops its session id.

pub mod context;
pub mod cycles;
pub mod effect;
pub mod remote;

use crate::harness::destructive::is_destructive;
use crate::harness::{HarnessConfiguration, HarnessEvent, HarnessKind, HarnessState};
use crate::intent::Intent;
use crate::status::{live_remote_turns, remote_turn_is_active, REMOTE_TURN_EXPIRY_SECONDS};
use crate::text::{capitalize_first, last_path_component, trim};

pub use context::{
    HarnessSnapshot, HookEvent, HookKind, PlacedPath, SessionContext, SessionSettings,
};
pub use effect::{ConfigChange, PendingPermission, RemoteKey, SessionEffect, TranscriptKind};
use remote::{
    cwd_label, focus_label, focus_order, in_project_folder, KnownSession, RemoteState,
    REMOTE_SESSION_MEMORY_SECONDS, UNKNOWN_SESSION,
};

/// The selected harness kind's normalized key plus the ACP agent and its
/// custom command: a change of any of them stops the outgoing session once.
fn harness_key(settings: &SessionSettings) -> String {
    [
        HarnessKind::from_setting(&settings.harness_kind).name(),
        settings.acp_agent.as_str(),
        settings.acp_custom_command.as_str(),
    ]
    .join("|")
}

/// The control mode as the rules read it: "remote" or "builtin".
fn normalized_control_mode(raw: &str) -> &'static str {
    if cycles::is_remote_mode(raw) {
        "remote"
    } else {
        "builtin"
    }
}

const TICK: SessionEffect = SessionEffect::Haptic {
    intensity: 0.5,
    duration: 0.05,
};
const INTERRUPT_BUZZ: SessionEffect = SessionEffect::Haptic {
    intensity: 0.6,
    duration: 0.08,
};
const REPLY_BUZZ: SessionEffect = SessionEffect::Haptic {
    intensity: 0.8,
    duration: 0.1,
};

/// One call's working copy of the context, and the effects so far.
struct Call {
    settings: SessionSettings,
    claude: HarnessSnapshot,
    acp: Option<HarnessSnapshot>,
    acp_agent_command: Option<Vec<String>>,
    now: f64,
    effects: Vec<SessionEffect>,
}

impl Call {
    fn new(ctx: &SessionContext) -> Call {
        Call {
            settings: ctx.settings.clone(),
            claude: ctx.claude.clone(),
            acp: ctx.acp.clone(),
            acp_agent_command: ctx.acp_agent_command.clone(),
            now: ctx.now,
            effects: Vec::new(),
        }
    }

    fn push(&mut self, effect: SessionEffect) {
        self.effects.push(effect);
    }

    fn append(&mut self, kind: TranscriptKind, text: impl Into<String>) {
        self.push(SessionEffect::AppendTranscript {
            kind,
            text: text.into(),
        });
    }

    fn system(&mut self, text: impl Into<String>) {
        self.append(TranscriptKind::System, text);
    }

    fn error(&mut self, text: impl Into<String>) {
        self.append(TranscriptKind::Error, text);
    }

    fn announce(&mut self, phrase: impl Into<String>) {
        self.push(SessionEffect::Announce(phrase.into()));
    }

    fn change(&mut self, change: ConfigChange) {
        match &change {
            ConfigChange::Model(value) => self.settings.model = value.clone(),
            ConfigChange::Effort(value) => self.settings.effort = value.clone(),
            ConfigChange::PermissionMode(value) => self.settings.permission_mode = value.clone(),
            ConfigChange::ControlMode(value) => self.settings.control_mode = value.clone(),
            ConfigChange::ProjectDir(path) => self.settings.project_dir = Some(path.clone()),
            ConfigChange::LastSessionId(id) => self.settings.last_session_id = id.clone(),
            ConfigChange::ProjectSessionId {
                project_dir,
                session_id,
            } => match session_id {
                Some(id) => {
                    self.settings
                        .session_ids_by_project
                        .insert(project_dir.clone(), id.clone());
                }
                None => {
                    self.settings.session_ids_by_project.remove(project_dir);
                }
            },
            ConfigChange::RecentProjectDirs(paths) => {
                self.settings.recent_project_dirs = paths.clone();
            }
        }
        self.push(SessionEffect::ChangeConfig(change));
    }

    fn is_remote(&self) -> bool {
        cycles::is_remote_mode(&self.settings.control_mode)
    }

    fn kind(&self) -> HarnessKind {
        HarnessKind::from_setting(&self.settings.harness_kind)
    }

    /// The selected adapter as it is now. An ACP adapter the platform has
    /// not created yet is a stopped one.
    fn active(&self) -> HarnessSnapshot {
        match self.kind() {
            HarnessKind::Claude => self.claude.clone(),
            HarnessKind::Acp => self.acp.clone().unwrap_or_else(HarnessSnapshot::stopped),
        }
    }

    fn snapshot_mut(&mut self, kind: HarnessKind) -> &mut HarnessSnapshot {
        match kind {
            HarnessKind::Claude => &mut self.claude,
            HarnessKind::Acp => self.acp.get_or_insert_with(HarnessSnapshot::stopped),
        }
    }

    /// The project folder, when one is chosen.
    fn project_dir(&self) -> Option<String> {
        self.settings
            .project_dir
            .clone()
            .filter(|dir| !dir.is_empty())
    }

    fn saved_session_id(&self, dir: &str) -> Option<String> {
        self.settings.session_ids_by_project.get(dir).cloned()
    }

    fn start(&mut self, kind: HarnessKind, configuration: HarnessConfiguration) {
        let snapshot = self.snapshot_mut(kind);
        snapshot.state = HarnessState::Starting;
        snapshot.session_id = configuration.resume_session_id.clone();
        snapshot.model_name = None;
        self.push(SessionEffect::StartHarness {
            harness: kind,
            configuration,
        });
    }

    fn send(&mut self, kind: HarnessKind, text: String) {
        self.snapshot_mut(kind).state = HarnessState::Working;
        self.push(SessionEffect::SendToHarness {
            harness: kind,
            text,
        });
    }

    fn stop(&mut self, kind: HarnessKind) {
        let snapshot = self.snapshot_mut(kind);
        snapshot.state = HarnessState::Stopped;
        if kind == HarnessKind::Acp {
            snapshot.session_id = None;
        }
        self.push(SessionEffect::StopHarness { harness: kind });
    }

    fn finish(self) -> Vec<SessionEffect> {
        self.effects
    }
}

/// AppState's session rules (see the module documentation).
#[derive(Debug, Clone, PartialEq)]
pub struct SessionMachine {
    /// The running session was started with a resume id (Claude only).
    started_with_resume: bool,
    /// The resume retry fires at most once per resumed id.
    has_retried_without_resume: bool,
    /// Exits PowerUp caused itself (a restart, a stop), which must not set
    /// off recovery. Reset on every launch, because the replaced process's
    /// exit then never arrives: a stale count would swallow a real crash and
    /// turn off the resume retry (HK-085).
    expected_terminations: u32,
    /// An effort change waiting for the turn in flight to end (HK-082).
    pending_effort_restart: bool,
    /// What the harness last confirmed, for rolling back a rejected live
    /// change; seeded from the command line at each start (HK-084).
    last_confirmed_model: String,
    last_confirmed_permission_mode: String,
    /// "Session started" is logged once per launch (HK-087).
    did_log_session_start: bool,
    pending_permission: Option<PendingPermission>,
    remote: RemoteState,
    last_harness_key: String,
    last_control_mode: &'static str,
}

impl SessionMachine {
    /// A machine for an app that has just come up. It adopts the stored
    /// control mode and harness selection as its baselines without acting
    /// on them (HK-166): launching in remote mode is not a switch into it.
    pub fn new(initial: &SessionSettings) -> SessionMachine {
        SessionMachine {
            started_with_resume: false,
            has_retried_without_resume: false,
            expected_terminations: 0,
            pending_effort_restart: false,
            last_confirmed_model: "default".to_owned(),
            last_confirmed_permission_mode: "acceptEdits".to_owned(),
            did_log_session_start: false,
            pending_permission: None,
            remote: RemoteState::default(),
            last_harness_key: harness_key(initial),
            last_control_mode: normalized_control_mode(&initial.control_mode),
        }
    }

    // MARK: Queries

    /// The permission request waiting for an answer.
    pub fn pending_permission(&self) -> Option<&PendingPermission> {
        self.pending_permission.as_ref()
    }

    /// A remote turn lights the working state.
    pub fn remote_turn_active(&self) -> bool {
        self.remote.active
    }

    /// The focused remote session, or `None` when every session is heard.
    pub fn remote_focus(&self) -> Option<&str> {
        self.remote.focus.as_deref()
    }

    /// The focused session's folder name, else the first eight characters
    /// of its id.
    pub fn remote_focus_label(&self) -> Option<String> {
        self.remote
            .focus
            .as_deref()
            .map(|focus| focus_label(&self.remote.known, focus))
    }

    // MARK: Public calls

    /// App launch and every send: start the selected harness when nothing
    /// is running, resuming the folder's own session (or the stored id).
    /// Remote mode never starts a session of its own (HK-118).
    pub fn start_session_if_needed(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.start_if_needed(&mut call);
        call.finish()
    }

    pub fn new_session(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.new_session_in(&mut call);
        call.finish()
    }

    pub fn send_user_text(&mut self, ctx: &SessionContext, text: &str) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.send_user_text_in(&mut call, text);
        call.finish()
    }

    pub fn interrupt(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.interrupt_in(&mut call);
        call.finish()
    }

    /// The banner's Allow and Deny buttons. They do nothing when nothing is
    /// waiting (HK-102): a click racing the request's end must not fall
    /// through to Approve's "send the word Yes".
    pub fn answer_pending_permission(
        &mut self,
        ctx: &SessionContext,
        allow: bool,
    ) -> Vec<SessionEffect> {
        if self.pending_permission.is_none() {
            return Vec::new();
        }
        let intent = if allow {
            Intent::Approve
        } else {
            Intent::Reject
        };
        self.handle_intent(ctx, &intent)
    }

    /// The folder picker: switch onto `path`, moving it to the front of the
    /// recents when asked.
    pub fn adopt_project(
        &mut self,
        ctx: &SessionContext,
        path: &str,
        move_to_front: bool,
    ) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.adopt_project_in(&mut call, path, move_to_front);
        call.finish()
    }

    /// The recents list's Switch button. A switch to the folder already
    /// chosen does nothing: reloading it would wipe the scrollback (HK-123).
    pub fn switch_project(&mut self, ctx: &SessionContext, path: &str) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.switch_project_in(&mut call, path);
        call.finish()
    }

    /// Cycle Project. `existing_recents` is the recents list, in order,
    /// keeping only folders that still exist on disk (the platform checks).
    /// It steps through them in list order without reordering them, or the
    /// next press would ping-pong back.
    pub fn cycle_project(
        &mut self,
        ctx: &SessionContext,
        existing_recents: &[String],
    ) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        if existing_recents.len() <= 1 {
            call.system("Only one project in the recent list — add more with the folder picker.");
            call.push(SessionEffect::ErrorHaptic);
            return call.finish();
        }
        let current = call.settings.project_dir.clone().unwrap_or_default();
        let next = match existing_recents.iter().position(|dir| *dir == current) {
            Some(index) => &existing_recents[(index + 1) % existing_recents.len()],
            None => &existing_recents[0],
        };
        call.push(TICK);
        self.switch_project_in(&mut call, next);
        call.finish()
    }

    /// Every intent from every input source. An armed destructive request
    /// is disarmed by anything but Approve, and stays pending (HK-098).
    /// The voice-capture intents, SendDraft, StopSpeaking, ReplayLastReply,
    /// ToggleTts, ShowWindow and CycleProject give only that disarm: the
    /// platform runs them (CycleProject through [`Self::cycle_project`]).
    pub fn handle_intent(&mut self, ctx: &SessionContext, intent: &Intent) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        if *intent != Intent::Approve {
            if let Some(pending) = self.pending_permission.as_ref().filter(|p| p.armed) {
                let mut disarmed = pending.clone();
                disarmed.armed = false;
                self.set_pending(&mut call, Some(disarmed));
            }
        }
        match intent {
            Intent::SendPrompt(prompt) => self.send_user_text_in(&mut call, prompt),
            Intent::Approve => self.approve(&mut call),
            Intent::Reject => self.reject(&mut call),
            Intent::Interrupt => self.interrupt_in(&mut call),
            Intent::NewSession => self.new_session_in(&mut call),
            Intent::CycleModel => self.cycle_model(&mut call),
            Intent::CycleEffort => self.cycle_effort(&mut call),
            Intent::CyclePermissionMode => self.cycle_permission_mode(&mut call),
            Intent::CycleFocus => self.cycle_focus(&mut call),
            Intent::ToggleControlMode => self.toggle_control_mode(&mut call),
            Intent::BeginVoiceCapture(_)
            | Intent::EndVoiceCapture
            | Intent::SendDraft
            | Intent::StopSpeaking
            | Intent::ReplayLastReply
            | Intent::ToggleTts
            | Intent::ShowWindow
            | Intent::CycleProject => {}
        }
        call.finish()
    }

    /// An adapter's event; `from` is the adapter that reported it. Events
    /// from an adapter that is not the selected harness are dropped, without
    /// even a status update (HK-124): a stopped claude process can still
    /// flush output and exit seconds later, and that late exit must not end
    /// the new session or run the resume retry on it.
    pub fn harness_event(
        &mut self,
        ctx: &SessionContext,
        from: HarnessKind,
        event: HarnessEvent,
    ) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        if from != call.kind() {
            return Vec::new();
        }
        self.harness_event_in(&mut call, event);
        call.push(SessionEffect::UpdateStatus);
        call.finish()
    }

    /// A Claude Code hook. `project` is the project folder as the platform
    /// placed it (`None` when no folder is chosen).
    pub fn hook_event(
        &mut self,
        ctx: &SessionContext,
        hook: &HookEvent,
        project: Option<&PlacedPath>,
    ) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.hook_event_in(&mut call, hook, project);
        call.finish()
    }

    /// A `ScheduleRemoteTurnCheck` fell due.
    pub fn remote_turn_check(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.refresh_remote_turn_active(&mut call);
        call.push(SessionEffect::UpdateStatus);
        call.finish()
    }

    /// A `DeferEffortRestart` hop ran. A turn that started meanwhile (a
    /// prompt already on its way) postpones the restart again (HK-082).
    pub fn deferred_effort_restart(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        if call.active().state == HarnessState::Working {
            self.pending_effort_restart = true;
            return call.finish();
        }
        self.restart_for_effort(&mut call);
        call.finish()
    }

    /// The platform's derived-update pass, after any settings change:
    /// first the control mode, then the harness selection. Each acts once
    /// per actual change, whoever made it.
    pub fn sync_settings(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.sync_control_mode(&mut call);
        self.sync_harness_selection(&mut call);
        call.finish()
    }

    /// A `SendToHarness` found its adapter stopped when it ran: its start
    /// failed at once.
    pub fn send_refused(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        call.error("No Claude session is running. Choose a project folder to start one.");
        call.push(SessionEffect::ErrorHaptic);
        call.push(SessionEffect::UpdateStatus);
        call.finish()
    }

    /// The app is quitting: stop our own session.
    pub fn shutdown(&mut self, ctx: &SessionContext) -> Vec<SessionEffect> {
        let mut call = Call::new(ctx);
        self.stop_active(&mut call);
        call.finish()
    }

    // MARK: Published state

    fn set_pending(&mut self, call: &mut Call, pending: Option<PendingPermission>) {
        if self.pending_permission != pending {
            self.pending_permission = pending.clone();
            call.push(SessionEffect::PendingPermissionChanged(pending));
        }
    }

    fn set_focus(&mut self, call: &mut Call, focus: Option<String>) {
        if self.remote.focus != focus {
            self.remote.focus = focus.clone();
            call.push(SessionEffect::RemoteFocusChanged(focus));
        }
    }

    fn set_remote_active(&mut self, call: &mut Call, active: bool) {
        if self.remote.active != active {
            self.remote.active = active;
            call.push(SessionEffect::RemoteTurnActiveChanged(active));
        }
    }

    // MARK: Approvals

    /// Approve: answers a waiting permission request first (a destructive
    /// one arms on the first press and confirms on the second). With none
    /// waiting, built-in mode sends the word "Yes" as a user turn (HK-100,
    /// DESIGN v1.0: Claude asks in its reply), and remote mode presses
    /// Enter in the target, where typing a word would answer a prompt with
    /// text instead of a choice (HK-101).
    fn approve(&mut self, call: &mut Call) {
        if !call.is_remote() {
            if let Some(pending) = self.pending_permission.clone() {
                if pending.is_destructive && !pending.armed {
                    let mut armed = pending;
                    armed.armed = true;
                    self.set_pending(call, Some(armed));
                    call.system("⚠️ Destructive action — press ✕ again to confirm, or ○ to deny.");
                    call.announce("Destructive. Press again to confirm");
                    call.push(SessionEffect::ErrorHaptic);
                    call.push(SessionEffect::UpdateStatus);
                    return;
                }
                self.set_pending(call, None);
                let harness = call.kind();
                call.push(SessionEffect::AnswerPermission {
                    harness,
                    id: pending.id,
                    allow: true,
                });
                call.system("Approved.");
                call.push(TICK);
                call.push(SessionEffect::UpdateStatus);
                return;
            }
            self.send_user_text_in(call, "Yes");
            return;
        }
        call.system("Approved (Enter).");
        call.push(SessionEffect::InjectKey(RemoteKey::Enter));
    }

    /// Reject: denies a waiting request first; with none, "No" in built-in
    /// mode and Escape in remote mode. Escape also stops a turn in flight,
    /// whose Stop hook never fires, so every remote turn is cleared first
    /// (HK-108).
    fn reject(&mut self, call: &mut Call) {
        if !call.is_remote() {
            if let Some(pending) = self.pending_permission.clone() {
                self.set_pending(call, None);
                let harness = call.kind();
                call.push(SessionEffect::AnswerPermission {
                    harness,
                    id: pending.id,
                    allow: false,
                });
                call.system("Denied.");
                call.push(TICK);
                call.push(SessionEffect::UpdateStatus);
                return;
            }
            self.send_user_text_in(call, "No");
            return;
        }
        self.clear_remote_turns(call);
        call.system("Rejected (Esc).");
        call.push(SessionEffect::InjectKey(RemoteKey::Escape));
        call.push(SessionEffect::UpdateStatus);
    }

    // MARK: Setting cycles

    /// Cycle Model. The CLI takes a live set_model, so a running session
    /// switches without losing its context; it is written already while
    /// the session starts, because the CLI buffers stdin and answers after
    /// init, which puts the change ahead of any turn sent before (HK-083).
    /// In remote mode the change is typed as `/model <alias>` and always
    /// submitted, whatever remoteAutoSubmit says (HK-107).
    fn cycle_model(&mut self, call: &mut Call) {
        let cycle = cycles::model_cycle(&call.settings.model_cycle);
        let next = cycles::next_value(&call.settings.model, &cycle);
        call.change(ConfigChange::Model(next.clone()));
        call.push(TICK);
        call.system(format!("Model → {next}"));
        let spoken = format!("Model: {}", capitalize_first(&next));
        if call.is_remote() {
            call.push(SessionEffect::InjectText {
                text: format!("/model {next}"),
                submit: true,
            });
            call.announce(spoken);
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        if call.active().state != HarnessState::Stopped {
            let harness = call.kind();
            call.push(SessionEffect::SetHarnessModel {
                harness,
                model: next,
            });
        }
        call.announce(spoken);
        call.push(SessionEffect::UpdateStatus);
    }

    /// Cycle Effort. There is no live effort switch: the CLI restarts with
    /// --effort and --resume, so the conversation carries on. Mid-turn the
    /// restart waits for the turn to end; with no session it applies at the
    /// next start (HK-082). A harness without the capability (ACP) refuses
    /// in built-in mode; remote mode types `/effort <level>` (HK-107).
    fn cycle_effort(&mut self, call: &mut Call) {
        if !call.is_remote() && !call.active().supports_effort {
            call.system("This harness doesn't have an effort setting.");
            call.push(SessionEffect::ErrorHaptic);
            return;
        }
        let next = cycles::next_value(&call.settings.effort, &cycles::EFFORT_CYCLE);
        call.change(ConfigChange::Effort(next.clone()));
        call.push(TICK);
        let display = cycles::effort_display_name(&next);
        if call.is_remote() {
            self.pending_effort_restart = false;
            call.system(format!("Effort → {display}"));
            call.push(SessionEffect::InjectText {
                text: format!("/effort {next}"),
                submit: true,
            });
            call.announce(format!("Effort: {display}"));
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        match call.active().state {
            HarnessState::Working => {
                self.pending_effort_restart = true;
                call.system(format!(
                    "Effort → {display} (applies when this turn finishes)"
                ));
            }
            HarnessState::Stopped => {
                self.pending_effort_restart = false;
                call.system(format!(
                    "Effort → {display} (applies when the session starts)"
                ));
            }
            HarnessState::Starting | HarnessState::Ready => {
                self.pending_effort_restart = false;
                call.system(format!("Effort → {display}"));
                self.restart_for_effort(call);
            }
        }
        call.announce(format!("Effort: {display}"));
        call.push(SessionEffect::UpdateStatus);
    }

    /// Cycle Permission Mode. In remote mode it presses Shift+Tab, which
    /// is how interactive Claude Code cycles, and leaves the setting alone:
    /// which mode the session lands on depends on where it was, and nothing
    /// reports it back (HK-106).
    fn cycle_permission_mode(&mut self, call: &mut Call) {
        if call.is_remote() {
            call.push(TICK);
            call.system("Permission mode cycled (see session)");
            call.push(SessionEffect::InjectKey(RemoteKey::ShiftTab));
            call.announce("Permission mode cycled");
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        let next = cycles::next_value(
            &call.settings.permission_mode,
            &cycles::PERMISSION_MODE_CYCLE,
        );
        call.change(ConfigChange::PermissionMode(next.clone()));
        call.push(TICK);
        call.system(format!("Permissions → {next}"));
        if call.active().state != HarnessState::Stopped {
            let harness = call.kind();
            call.push(SessionEffect::SetHarnessPermissionMode {
                harness,
                mode: next.clone(),
            });
        }
        call.announce(format!("Permissions: {next}"));
        call.push(SessionEffect::UpdateStatus);
    }

    /// Relaunches the harness so a new effort takes hold, resuming the
    /// session so nothing said so far is lost.
    fn restart_for_effort(&mut self, call: &mut Call) {
        if call.active().state == HarnessState::Stopped {
            return;
        }
        if call.project_dir().is_none() {
            return;
        }
        let resume = call
            .active()
            .session_id
            .or_else(|| call.settings.last_session_id.clone());
        call.system(format!(
            "Resuming the session with effort {}…",
            call.settings.effort
        ));
        self.start_session(call, resume);
    }

    // MARK: Session control

    fn start_if_needed(&mut self, call: &mut Call) {
        if call.is_remote() || call.active().state != HarnessState::Stopped {
            return;
        }
        let Some(dir) = call.project_dir() else {
            return;
        };
        let resume = call
            .saved_session_id(&dir)
            .or_else(|| call.settings.last_session_id.clone());
        self.start_session(call, resume);
    }

    fn new_session_in(&mut self, call: &mut Call) {
        call.push(SessionEffect::CancelSummary);
        call.push(SessionEffect::StopSpeaking);
        // The old session's permission request dies with it.
        self.set_pending(call, None);
        call.push(SessionEffect::ClearLiveReply);
        if call.is_remote() {
            // PowerUp does not own the remote session: a new session there
            // means clearing the conversation it holds (HK-107).
            self.clear_remote_turns(call);
            call.system("Clearing the remote session.");
            call.push(SessionEffect::InjectText {
                text: "/clear".to_owned(),
                submit: true,
            });
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        self.has_retried_without_resume = false;
        self.started_with_resume = false;
        self.pending_effort_restart = false;
        call.change(ConfigChange::LastSessionId(None));
        if let Some(dir) = call.project_dir() {
            call.change(ConfigChange::ProjectSessionId {
                project_dir: dir,
                session_id: None,
            });
        }
        call.system("Starting a new Claude session.");
        if call.project_dir().is_some() {
            self.start_session(call, None);
        } else {
            self.stop_active(call);
            call.system("Choose a project folder to begin.");
        }
        call.push(SessionEffect::UpdateStatus);
    }

    fn send_user_text_in(&mut self, call: &mut Call, text: &str) {
        let trimmed = trim(text);
        if trimmed.is_empty() {
            return;
        }
        call.append(TranscriptKind::User, trimmed);
        call.push(SessionEffect::CancelSummary);
        call.push(SessionEffect::ClearLiveReply);
        if call.is_remote() {
            let submit = call.settings.remote_auto_submit;
            call.push(SessionEffect::InjectText {
                text: trimmed.to_owned(),
                submit,
            });
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        self.start_if_needed(call);
        if call.active().state == HarnessState::Stopped {
            call.error("No Claude session is running. Choose a project folder to start one.");
            call.push(SessionEffect::ErrorHaptic);
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        let outgoing = Self::outgoing_text(call, trimmed);
        let harness = call.kind();
        call.send(harness, outgoing);
        call.push(SessionEffect::UpdateStatus);
    }

    /// At Ultra effort ("max") on the built-in Claude harness, a prompt opts
    /// into dynamic multi-agent workflows with Claude Code's `ultracode`
    /// keyword (DESIGN v2.1, HK-081). The transcript keeps the person's own
    /// words; other harnesses and remote mode are never prefixed.
    fn outgoing_text(call: &Call, text: &str) -> String {
        if call.settings.effort == "max" && call.kind() == HarnessKind::Claude {
            format!("ultracode\n\n{text}")
        } else {
            text.to_owned()
        }
    }

    /// Interrupt. Remote mode presses Escape (clearing every turn, whose
    /// Stop hook never fires, HK-108). Built-in mode with nothing running
    /// says so instead of confirming (HK-104): the Claude adapter drops an
    /// interrupt silently without a live process. The waiting permission
    /// request goes with the cancelled turn, unanswered (HK-103).
    fn interrupt_in(&mut self, call: &mut Call) {
        if call.is_remote() {
            self.clear_remote_turns(call);
            call.system("Interrupt sent (Esc).");
            call.push(INTERRUPT_BUZZ);
            call.push(SessionEffect::InjectKey(RemoteKey::Escape));
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        if call.active().state == HarnessState::Stopped {
            call.error("No Claude session is running — nothing to interrupt.");
            call.push(SessionEffect::ErrorHaptic);
            call.push(SessionEffect::UpdateStatus);
            return;
        }
        let harness = call.kind();
        call.push(SessionEffect::InterruptHarness { harness });
        self.set_pending(call, None);
        call.system("Interrupt sent.");
        call.push(INTERRUPT_BUZZ);
        call.push(SessionEffect::UpdateStatus);
    }

    // MARK: Projects

    /// Switches onto a project folder: its own session id (each folder is
    /// its own conversation), its own transcript history and, in built-in
    /// mode, a session resuming that folder's conversation (HK-123). In
    /// remote mode the folder decides which sessions are heard, so a real
    /// change ends the old folder's turns, registry and focus (HK-119).
    fn adopt_project_in(&mut self, call: &mut Call, path: &str, move_to_front: bool) {
        let changed = call.settings.project_dir.as_deref() != Some(path);
        call.change(ConfigChange::ProjectDir(path.to_owned()));
        if changed {
            let saved = call.saved_session_id(path);
            call.change(ConfigChange::LastSessionId(saved));
        }
        self.has_retried_without_resume = false;
        Self::add_to_recents(call, path, move_to_front);
        call.push(SessionEffect::ShowProjectTranscript {
            project_dir: path.to_owned(),
            restore_history: changed,
        });
        call.system(format!("Project folder: {}", last_path_component(path)));
        if !call.is_remote() {
            let saved = call.saved_session_id(path);
            self.start_session(call, saved);
        } else if changed {
            self.clear_remote_turns(call);
            self.remote.known.clear();
            self.set_focus(call, None);
        }
        call.push(SessionEffect::UpdateStatus);
    }

    fn switch_project_in(&mut self, call: &mut Call, path: &str) {
        if call.settings.project_dir.as_deref() == Some(path) {
            return;
        }
        call.push(SessionEffect::CancelSummary);
        call.push(SessionEffect::StopSpeaking);
        call.push(SessionEffect::ClearLiveReply);
        self.set_pending(call, None);
        self.adopt_project_in(call, path, false);
        call.announce(format!("Project: {}", last_path_component(path)));
    }

    /// The recents list, newest first and at most eight (HK-167): the
    /// picker moves a folder to the front, a switch only adds a new one.
    /// Written only when it changes.
    fn add_to_recents(call: &mut Call, path: &str, front: bool) {
        let mut recents = call.settings.recent_project_dirs.clone();
        if front {
            recents.retain(|dir| dir != path);
            recents.insert(0, path.to_owned());
        } else if !recents.iter().any(|dir| dir == path) {
            recents.insert(0, path.to_owned());
        }
        recents.truncate(8);
        if recents != call.settings.recent_project_dirs {
            call.change(ConfigChange::RecentProjectDirs(recents));
        }
    }

    // MARK: Control mode and harness selection

    fn toggle_control_mode(&mut self, call: &mut Call) {
        let mode = if call.is_remote() {
            "builtin"
        } else {
            "remote"
        };
        call.change(ConfigChange::ControlMode(mode.to_owned()));
        call.push(TICK);
        self.sync_control_mode(call);
    }

    /// The switch-over work, once per actual mode change: the remote turns,
    /// the focus and a waiting permission request belong to the mode being
    /// left (HK-105: in remote mode the same buttons press keys in the real
    /// session). Entering remote mode stops our own session, which would
    /// otherwise burn a seat and echo its hooks back (HK-118).
    fn sync_control_mode(&mut self, call: &mut Call) {
        let mode = normalized_control_mode(&call.settings.control_mode);
        if mode == self.last_control_mode {
            return;
        }
        self.last_control_mode = mode;
        self.clear_remote_turns(call);
        self.set_focus(call, None);
        self.set_pending(call, None);
        call.push(SessionEffect::ClearLiveReply);
        if mode == "remote" {
            self.stop_active(call);
            call.push(SessionEffect::RefreshRemoteStatus);
            call.system(
                "Remote control mode — buttons and voice now drive your existing Claude session.",
            );
            call.announce("Remote control");
        } else {
            call.system("Built-in session mode — PowerUp runs its own Claude session again.");
            call.announce("Built-in session");
        }
        call.push(SessionEffect::UpdateStatus);
    }

    /// A Settings change of harness kind, ACP agent or custom command stops
    /// the outgoing session exactly once; the new harness starts lazily with
    /// the next message (HK-125). Only the Claude adapter's stop counts as an
    /// expected exit: the ACP adapter reports none for a stop.
    fn sync_harness_selection(&mut self, call: &mut Call) {
        let key = harness_key(&call.settings);
        if key == self.last_harness_key {
            return;
        }
        self.last_harness_key = key;
        self.set_pending(call, None);
        call.push(SessionEffect::CancelSummary);
        if call
            .acp
            .as_ref()
            .is_some_and(|acp| acp.state != HarnessState::Stopped)
        {
            call.stop(HarnessKind::Acp);
        }
        if call.claude.state != HarnessState::Stopped {
            self.expected_terminations += 1;
            call.stop(HarnessKind::Claude);
        }
        let text = match call.kind() {
            HarnessKind::Acp => format!(
                "Harness → {} (ACP). The session starts with your next message.",
                cycles::acp_agent_display_name(&call.settings.acp_agent)
            ),
            HarnessKind::Claude => {
                "Harness → built-in Claude Code. The session starts with your next message."
                    .to_owned()
            }
        };
        call.system(text);
        call.push(SessionEffect::UpdateStatus);
    }

    // MARK: Remote read-back

    /// A hook fired somewhere on this machine. Only remote mode cares.
    /// Hooks from the session PowerUp runs itself are dropped, or its own
    /// replies would come back as read-back, and so are hooks from outside
    /// the project folder (HK-112).
    fn hook_event_in(&mut self, call: &mut Call, hook: &HookEvent, project: Option<&PlacedPath>) {
        if !call.is_remote() {
            return;
        }
        if let (Some(id), Some(ours)) = (&hook.session_id, &call.active().session_id) {
            if id == ours {
                return;
            }
        }
        let project_dir = call.settings.project_dir.clone();
        if !in_project_folder(project_dir.as_deref(), project, hook) {
            return;
        }
        let key = hook
            .session_id
            .clone()
            .unwrap_or_else(|| UNKNOWN_SESSION.to_owned());
        // Every hook but SessionEnd is a sighting for the focus cycle.
        if hook.kind != HookKind::SessionEnd {
            let cwd = hook.cwd.clone().or_else(|| {
                self.remote
                    .known
                    .get(&key)
                    .and_then(|known| known.cwd.clone())
            });
            self.remote.known.insert(
                key.clone(),
                KnownSession {
                    cwd,
                    last_seen: call.now,
                },
            );
        }
        // With a focus set only the focused session speaks, buzzes and
        // drives the working light; everything still logs (HK-116).
        let is_focused = self
            .remote
            .focus
            .as_deref()
            .is_none_or(|focus| focus == key);
        let label = || cwd_label(project_dir.as_deref(), project, hook);
        match hook.kind {
            // PostToolUse is the turn's heartbeat: it re-arms the expiry,
            // and can start a turn already running (HK-110).
            HookKind::UserPromptSubmit | HookKind::PostToolUse => {
                self.begin_remote_turn(call, &key);
            }
            HookKind::SessionEnd => {
                // The only signal a session closed mid-turn ever sends
                // (HK-111); only one believed to be working is worth a note.
                self.remote.known.remove(&key);
                if self.remote.focus.as_deref() == Some(key.as_str()) {
                    self.set_focus(call, None);
                    call.system("Focused session ended — back to hearing everything.");
                }
                if self.remote.turns.remove(&key).is_some() {
                    call.system(format!("{}Claude session ended before replying.", label()));
                }
                self.refresh_remote_turn_active(call);
            }
            HookKind::Stop => {
                self.remote.turns.remove(&key);
                self.refresh_remote_turn_active(call);
                let reply = trim(hook.text.as_deref().unwrap_or_default());
                if !reply.is_empty() {
                    call.append(TranscriptKind::Assistant, format!("{}{reply}", label()));
                    if is_focused {
                        // Without the label, so Replay speaks the reply
                        // and not a folder name (HK-114).
                        call.push(SessionEffect::SetLastReply(reply.to_owned()));
                        call.push(REPLY_BUZZ);
                        call.push(SessionEffect::SpeakReply(reply.to_owned()));
                    }
                }
            }
            HookKind::Notification => {
                // A sign of life from a turn waiting on the person: it
                // re-arms a running turn's expiry, but never starts one.
                if self.remote.turns.contains_key(&key) {
                    self.begin_remote_turn(call, &key);
                }
                let message = trim(hook.text.as_deref().unwrap_or_default());
                call.system(if message.is_empty() {
                    "Claude needs your attention."
                } else {
                    message
                });
                if is_focused {
                    call.announce("Claude needs your attention");
                }
            }
        }
        call.push(SessionEffect::UpdateStatus);
    }

    /// Records a turn's sign of life and schedules the check that expires
    /// it if every ending signal is missed. Each heartbeat re-arms it, so a
    /// turn kept alive that then dies silently still goes idle 15 minutes
    /// after its last sign of life.
    fn begin_remote_turn(&mut self, call: &mut Call, key: &str) {
        self.remote.turns.insert(key.to_owned(), call.now);
        self.refresh_remote_turn_active(call);
        call.push(SessionEffect::ScheduleRemoteTurnCheck {
            after_seconds: REMOTE_TURN_EXPIRY_SECONDS + 1.0,
        });
    }

    fn refresh_remote_turn_active(&mut self, call: &mut Call) {
        self.remote.turns =
            live_remote_turns(&self.remote.turns, call.now, REMOTE_TURN_EXPIRY_SECONDS);
        let active = remote_turn_is_active(&self.remote.turns, self.remote.focus.as_deref());
        self.set_remote_active(call, active);
    }

    /// The hard reset: Interrupt, Reject and New Session in remote mode, and
    /// every mode switch.
    fn clear_remote_turns(&mut self, call: &mut Call) {
        self.remote.turns.clear();
        self.set_remote_active(call, false);
    }

    /// Cycle Session Focus: All, then each session seen in the last 30
    /// minutes in folder-name order, then All again (HK-117).
    fn cycle_focus(&mut self, call: &mut Call) {
        if !call.is_remote() {
            call.system("Session focus applies to Remote Control mode.");
            call.push(SessionEffect::ErrorHaptic);
            return;
        }
        let cutoff = call.now - REMOTE_SESSION_MEMORY_SECONDS;
        self.remote
            .known
            .retain(|_, known| known.last_seen > cutoff);
        let ordered = focus_order(&self.remote.known);
        if ordered.is_empty() {
            call.system("No remote sessions seen yet — focus needs read-back activity first.");
            call.push(SessionEffect::ErrorHaptic);
            return;
        }
        call.push(TICK);
        let current = self
            .remote
            .focus
            .as_ref()
            .and_then(|focus| ordered.iter().position(|id| id == focus));
        let next = match current {
            Some(index) => ordered.get(index + 1).cloned(),
            None => ordered.first().cloned(),
        };
        self.set_focus(call, next);
        self.refresh_remote_turn_active(call);
        match self.remote_focus_label() {
            Some(label) => {
                call.system(format!(
                    "Focus → {label} — only this session is spoken now."
                ));
                call.announce(format!("Focus: {label}"));
            }
            None => {
                call.system("Focus → all sessions.");
                call.announce("Focus: everything");
            }
        }
        call.push(SessionEffect::UpdateStatus);
    }

    // MARK: Session plumbing

    fn start_session(&mut self, call: &mut Call, resume: Option<String>) {
        let Some(dir) = call.project_dir() else {
            return;
        };
        let kind = call.kind();
        self.expected_terminations = 0;
        // An ACP session always starts fresh, so it is never a resume: the
        // resume retry must not fire for an agent's crash, or it would wipe
        // the stored Claude id (HK-137).
        self.started_with_resume = resume.is_some() && kind == HarnessKind::Claude;
        call.push(SessionEffect::ClearLiveReply);
        // A queued effort change is satisfied by this launch.
        self.pending_effort_restart = false;
        self.did_log_session_start = false;
        // These go in on the command line, so the harness runs them by
        // definition.
        self.last_confirmed_model = call.settings.model.clone();
        self.last_confirmed_permission_mode = call.settings.permission_mode.clone();
        let agent_command = match kind {
            HarnessKind::Claude => None,
            HarnessKind::Acp => match call.acp_agent_command.clone() {
                Some(command) => Some(command),
                None => {
                    call.error(format!(
                        "Couldn't find the {} command — install it, or pick another harness in Settings → General.",
                        cycles::acp_agent_display_name(&call.settings.acp_agent)
                    ));
                    call.push(SessionEffect::UpdateStatus);
                    return;
                }
            },
        };
        let configuration = HarnessConfiguration {
            project_dir: dir,
            model: call.settings.model.clone(),
            permission_mode: call.settings.permission_mode.clone(),
            effort: call.settings.effort.clone(),
            resume_session_id: if kind == HarnessKind::Acp {
                None
            } else {
                resume
            },
            binary_path_override: call.settings.claude_path.clone(),
            agent_command,
        };
        call.start(kind, configuration);
        call.push(SessionEffect::UpdateStatus);
    }

    fn stop_active(&mut self, call: &mut Call) {
        if call.active().state == HarnessState::Stopped {
            return;
        }
        self.expected_terminations += 1;
        let kind = call.kind();
        call.stop(kind);
    }

    // MARK: Harness events

    fn harness_event_in(&mut self, call: &mut Call, event: HarnessEvent) {
        match event {
            HarnessEvent::SessionReady { session_id, model } => {
                // Only the Claude adapter's ids resume with --resume; an
                // ACP id must never replace the stored one.
                if call.kind() == HarnessKind::Claude {
                    call.change(ConfigChange::LastSessionId(Some(session_id.clone())));
                    if let Some(dir) = call.project_dir() {
                        call.change(ConfigChange::ProjectSessionId {
                            project_dir: dir,
                            session_id: Some(session_id),
                        });
                    }
                }
                if !self.did_log_session_start {
                    self.did_log_session_start = true;
                    // The resume worked (or the start was fresh): a later
                    // exit is not the id's fault (HK-086).
                    self.started_with_resume = false;
                    self.has_retried_without_resume = false;
                    call.system(format!("Session started ({model})"));
                }
            }
            HarnessEvent::ReplyDelta(chunk) => call.push(SessionEffect::AppendLiveReply(chunk)),
            HarnessEvent::Reply(message) => {
                call.push(SessionEffect::ClearLiveReply);
                let trimmed = trim(&message);
                if !trimmed.is_empty() {
                    call.append(TranscriptKind::Assistant, trimmed);
                }
            }
            HarnessEvent::ToolUse { name, detail } => {
                let detail = trim(&detail);
                call.append(
                    TranscriptKind::Tool,
                    if detail.is_empty() {
                        name
                    } else {
                        format!("{name} — {detail}")
                    },
                );
            }
            HarnessEvent::TurnCompleted {
                result_text,
                is_error,
                detail,
                ..
            } => {
                self.set_pending(call, None);
                call.push(SessionEffect::ClearLiveReply);
                let result = trim(result_text.as_deref().unwrap_or_default()).to_owned();
                if is_error {
                    // An error result is not an answer: never spoken, never
                    // replayed (HK-089).
                    let shown = if result.is_empty() {
                        String::new()
                    } else {
                        format!("\n{result}")
                    };
                    call.error(format!(
                        "Claude ended the turn with an error ({detail}).{shown}"
                    ));
                    call.push(SessionEffect::ErrorHaptic);
                } else {
                    // The spoken reply is the turn's result text, not the
                    // streamed message.
                    if !result.is_empty() {
                        call.push(SessionEffect::SetLastReply(result.clone()));
                    }
                    call.push(REPLY_BUZZ);
                    call.push(SessionEffect::SpeakReply(result));
                }
                if self.pending_effort_restart {
                    // Off this delivery, never inline: the rest of the batch
                    // must still reach the session that produced it.
                    self.pending_effort_restart = false;
                    call.push(SessionEffect::DeferEffortRestart);
                }
            }
            HarnessEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            } => self.handle_control_result(call, &action, ok, &detail, value),
            HarnessEvent::PermissionRequest {
                id,
                name,
                kind,
                detail,
            } => {
                let destructive = is_destructive(&kind, &name, &detail);
                let what = if detail.is_empty() {
                    name.clone()
                } else {
                    format!("{name} — {detail}")
                };
                self.set_pending(
                    call,
                    Some(PendingPermission {
                        id,
                        name,
                        detail,
                        is_destructive: destructive,
                        armed: false,
                    }),
                );
                call.system(if destructive {
                    format!(
                        "⚠️ The agent wants to: {what}. Destructive — ✕ twice to allow, ○ to deny."
                    )
                } else {
                    format!("The agent wants to: {what}. Press ✕ to allow or ○ to deny.")
                });
                call.push(REPLY_BUZZ);
                call.announce(if destructive {
                    "Destructive approval needed"
                } else {
                    "Approval needed"
                });
            }
            HarnessEvent::Notification(message) => {
                let trimmed = trim(&message);
                call.system(if trimmed.is_empty() {
                    "Claude needs your attention."
                } else {
                    trimmed
                });
                call.announce("Claude needs your attention");
            }
            HarnessEvent::RuntimeError(message) => call.error(message),
            HarnessEvent::Ended { exit_code } => {
                self.set_pending(call, None);
                self.handle_termination(call, exit_code);
            }
        }
    }

    /// The answer to one of our control requests. A success only moves the
    /// confirmed value, taken from what the acknowledged request asked for:
    /// with two requests in flight the config already holds the newer one.
    /// A failure rolls back only while the rejected value is still showing;
    /// otherwise a newer request owns the field (HK-084).
    fn handle_control_result(
        &mut self,
        call: &mut Call,
        action: &str,
        ok: bool,
        detail: &str,
        value: Option<String>,
    ) {
        if ok {
            match action {
                "set_model" => {
                    self.last_confirmed_model =
                        value.unwrap_or_else(|| call.settings.model.clone());
                }
                "set_permission_mode" => {
                    self.last_confirmed_permission_mode =
                        value.unwrap_or_else(|| call.settings.permission_mode.clone());
                }
                _ => {}
            }
            return;
        }
        let reason = trim(detail);
        call.error(if reason.is_empty() {
            format!("Couldn't apply {action}.")
        } else {
            format!("Couldn't apply {action}: {reason}")
        });
        call.push(SessionEffect::ErrorHaptic);
        match action {
            "set_model" => {
                let rejected = value.unwrap_or_else(|| call.settings.model.clone());
                if call.settings.model == rejected
                    && call.settings.model != self.last_confirmed_model
                {
                    let confirmed = self.last_confirmed_model.clone();
                    call.change(ConfigChange::Model(confirmed.clone()));
                    call.system(format!("Model stays {confirmed}."));
                }
            }
            "set_permission_mode" => {
                let rejected = value.unwrap_or_else(|| call.settings.permission_mode.clone());
                if call.settings.permission_mode == rejected
                    && call.settings.permission_mode != self.last_confirmed_permission_mode
                {
                    let confirmed = self.last_confirmed_permission_mode.clone();
                    call.change(ConfigChange::PermissionMode(confirmed.clone()));
                    call.system(format!("Permissions stay {confirmed}."));
                }
            }
            _ => {}
        }
    }

    /// The session ended. An exit PowerUp caused is only counted off. A
    /// resumed launch that dies is retried once as a fresh session, and the
    /// stale id is forgotten everywhere it is kept, or the next start would
    /// resume it again with the retry already spent (HK-086).
    fn handle_termination(&mut self, call: &mut Call, exit_code: i32) {
        if self.expected_terminations > 0 {
            self.expected_terminations -= 1;
            return;
        }
        if self.started_with_resume && !self.has_retried_without_resume {
            self.started_with_resume = false;
            self.has_retried_without_resume = true;
            call.change(ConfigChange::LastSessionId(None));
            if let Some(dir) = call.project_dir() {
                call.change(ConfigChange::ProjectSessionId {
                    project_dir: dir,
                    session_id: None,
                });
            }
            call.system("Couldn't resume the previous session — starting a fresh one.");
            self.start_session(call, None);
            return;
        }
        if exit_code == 0 {
            call.system("Claude session ended.");
        } else {
            call.error(format!(
                "Claude session ended unexpectedly (exit code {exit_code})."
            ));
        }
    }
}

#[cfg(test)]
mod tests;
