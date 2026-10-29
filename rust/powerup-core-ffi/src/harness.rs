//! The Claude harness half of slice 2.3: the stdout line buffer, the
//! stream-json line parser, the stdin lines, the launch arguments and the
//! Claude adapter's process rules.
//!
//! As in `mapping`, the types are the uniffi faces of their `powerup-core`
//! twins with a `Core` prefix (DESIGN v2.12 A), converted both ways with
//! exhaustive matches. The two objects here, `CoreLineBuffer` and
//! `CoreClaudeAdapter`, are owned by Swift and never call back: every call
//! returns its lines, events or effects, and Swift acts on them.

use std::sync::{Arc, Mutex};

use powerup_core::harness::claude::adapter::{ClaudeAdapter, ClaudeAdapterEffect, ClaudeSnapshot};
use powerup_core::harness::claude::event::ClaudeEvent;
use powerup_core::harness::claude::launch;
use powerup_core::harness::claude::lines::LineBuffer;
use powerup_core::harness::claude::parse;
use powerup_core::harness::claude::stdin::{self, ControlRequest};
use powerup_core::harness::{HarnessConfiguration, HarnessEvent, HarnessState};
use powerup_core::CoreError;

use crate::{contain, locked, CoreBridgeError};

/// One event parsed from a claude stdout line, case for case with
/// `powerup_core::harness::claude::event::ClaudeEvent`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreClaudeEvent {
    Ready {
        session_id: String,
        model: String,
    },
    TextDelta {
        text: String,
    },
    AssistantMessage {
        text: String,
    },
    ToolUse {
        name: String,
        detail: String,
    },
    TurnCompleted {
        result_text: Option<String>,
        cost_usd: Option<f64>,
        is_error: bool,
        subtype: String,
    },
    ControlResult {
        action: String,
        ok: bool,
        detail: String,
        value: Option<String>,
    },
    ProcessError {
        message: String,
    },
    Terminated {
        exit_code: i32,
    },
}

impl From<ClaudeEvent> for CoreClaudeEvent {
    fn from(event: ClaudeEvent) -> Self {
        match event {
            ClaudeEvent::Ready { session_id, model } => {
                CoreClaudeEvent::Ready { session_id, model }
            }
            ClaudeEvent::TextDelta(text) => CoreClaudeEvent::TextDelta { text },
            ClaudeEvent::AssistantMessage(text) => CoreClaudeEvent::AssistantMessage { text },
            ClaudeEvent::ToolUse { name, detail } => CoreClaudeEvent::ToolUse { name, detail },
            ClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            } => CoreClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            },
            ClaudeEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            } => CoreClaudeEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            },
            ClaudeEvent::ProcessError(message) => CoreClaudeEvent::ProcessError { message },
            ClaudeEvent::Terminated { exit_code } => CoreClaudeEvent::Terminated { exit_code },
        }
    }
}

impl From<CoreClaudeEvent> for ClaudeEvent {
    fn from(event: CoreClaudeEvent) -> Self {
        match event {
            CoreClaudeEvent::Ready { session_id, model } => {
                ClaudeEvent::Ready { session_id, model }
            }
            CoreClaudeEvent::TextDelta { text } => ClaudeEvent::TextDelta(text),
            CoreClaudeEvent::AssistantMessage { text } => ClaudeEvent::AssistantMessage(text),
            CoreClaudeEvent::ToolUse { name, detail } => ClaudeEvent::ToolUse { name, detail },
            CoreClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            } => ClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            },
            CoreClaudeEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            } => ClaudeEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            },
            CoreClaudeEvent::ProcessError { message } => ClaudeEvent::ProcessError(message),
            CoreClaudeEvent::Terminated { exit_code } => ClaudeEvent::Terminated { exit_code },
        }
    }
}

/// What one stdout line (without its newline) means; anything the parser
/// does not recognize gives no events (`parse::events_from_line`).
#[uniffi::export]
pub fn claude_events_from_line(line: Vec<u8>) -> Result<Vec<CoreClaudeEvent>, CoreBridgeError> {
    contain(|| {
        Ok(parse::events_from_line(&line)
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

/// The stdout bytes of one launch that no newline has finished yet
/// (`lines::LineBuffer`, HK-052, HK-053). Swift creates one per launch and
/// drops it with the launch. The pipe's reader threads call it, so it locks
/// its own state; each launch has its own buffer, so the lock is never
/// contended in the app.
#[derive(Debug, uniffi::Object)]
pub struct CoreLineBuffer {
    buffer: Mutex<LineBuffer>,
}

#[uniffi::export]
impl CoreLineBuffer {
    /// An empty buffer that drops a tail past 16 MiB.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreBridgeError> {
        contain(|| {
            Ok(Arc::new(CoreLineBuffer {
                buffer: Mutex::new(LineBuffer::new()),
            }))
        })
    }

    /// Appends `chunk` and returns every line it finishes, in order; the
    /// tail waits for the next chunk.
    pub fn ingest(&self, chunk: Vec<u8>) -> Result<Vec<Vec<u8>>, CoreBridgeError> {
        contain(|| Ok(locked(&self.buffer).ingest(&chunk)))
    }

    /// The buffered tail once the stream has ended, or none; empties the
    /// buffer.
    pub fn flush_remainder(&self) -> Result<Option<Vec<u8>>, CoreBridgeError> {
        contain(|| Ok(locked(&self.buffer).flush()))
    }
}

/// The lifecycle of a harness session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreHarnessState {
    Stopped,
    Starting,
    Ready,
    Working,
}

impl From<HarnessState> for CoreHarnessState {
    fn from(state: HarnessState) -> Self {
        match state {
            HarnessState::Stopped => CoreHarnessState::Stopped,
            HarnessState::Starting => CoreHarnessState::Starting,
            HarnessState::Ready => CoreHarnessState::Ready,
            HarnessState::Working => CoreHarnessState::Working,
        }
    }
}

impl From<CoreHarnessState> for HarnessState {
    fn from(state: CoreHarnessState) -> Self {
        match state {
            CoreHarnessState::Stopped => HarnessState::Stopped,
            CoreHarnessState::Starting => HarnessState::Starting,
            CoreHarnessState::Ready => HarnessState::Ready,
            CoreHarnessState::Working => HarnessState::Working,
        }
    }
}

/// Everything an adapter needs to start (or resume) a session.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHarnessConfiguration {
    pub project_dir: String,
    pub model: String,
    pub permission_mode: String,
    pub effort: String,
    pub resume_session_id: Option<String>,
    pub binary_path_override: Option<String>,
    pub agent_command: Option<Vec<String>>,
}

impl From<HarnessConfiguration> for CoreHarnessConfiguration {
    fn from(configuration: HarnessConfiguration) -> Self {
        CoreHarnessConfiguration {
            project_dir: configuration.project_dir,
            model: configuration.model,
            permission_mode: configuration.permission_mode,
            effort: configuration.effort,
            resume_session_id: configuration.resume_session_id,
            binary_path_override: configuration.binary_path_override,
            agent_command: configuration.agent_command,
        }
    }
}

impl From<CoreHarnessConfiguration> for HarnessConfiguration {
    fn from(configuration: CoreHarnessConfiguration) -> Self {
        HarnessConfiguration {
            project_dir: configuration.project_dir,
            model: configuration.model,
            permission_mode: configuration.permission_mode,
            effort: configuration.effort,
            resume_session_id: configuration.resume_session_id,
            binary_path_override: configuration.binary_path_override,
            agent_command: configuration.agent_command,
        }
    }
}

/// The normalized event every harness adapter produces, case for case with
/// `powerup_core::harness::HarnessEvent`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreHarnessEvent {
    SessionReady {
        session_id: String,
        model: String,
    },
    ReplyDelta {
        text: String,
    },
    Reply {
        text: String,
    },
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
    ControlResult {
        action: String,
        ok: bool,
        detail: String,
        value: Option<String>,
    },
    PermissionRequest {
        id: String,
        name: String,
        kind: String,
        detail: String,
    },
    Notification {
        message: String,
    },
    RuntimeError {
        message: String,
    },
    Ended {
        exit_code: i32,
    },
}

impl From<HarnessEvent> for CoreHarnessEvent {
    fn from(event: HarnessEvent) -> Self {
        match event {
            HarnessEvent::SessionReady { session_id, model } => {
                CoreHarnessEvent::SessionReady { session_id, model }
            }
            HarnessEvent::ReplyDelta(text) => CoreHarnessEvent::ReplyDelta { text },
            HarnessEvent::Reply(text) => CoreHarnessEvent::Reply { text },
            HarnessEvent::ToolUse { name, detail } => CoreHarnessEvent::ToolUse { name, detail },
            HarnessEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                detail,
            } => CoreHarnessEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                detail,
            },
            HarnessEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            } => CoreHarnessEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            },
            HarnessEvent::PermissionRequest {
                id,
                name,
                kind,
                detail,
            } => CoreHarnessEvent::PermissionRequest {
                id,
                name,
                kind,
                detail,
            },
            HarnessEvent::Notification(message) => CoreHarnessEvent::Notification { message },
            HarnessEvent::RuntimeError(message) => CoreHarnessEvent::RuntimeError { message },
            HarnessEvent::Ended { exit_code } => CoreHarnessEvent::Ended { exit_code },
        }
    }
}

impl From<CoreHarnessEvent> for HarnessEvent {
    fn from(event: CoreHarnessEvent) -> Self {
        match event {
            CoreHarnessEvent::SessionReady { session_id, model } => {
                HarnessEvent::SessionReady { session_id, model }
            }
            CoreHarnessEvent::ReplyDelta { text } => HarnessEvent::ReplyDelta(text),
            CoreHarnessEvent::Reply { text } => HarnessEvent::Reply(text),
            CoreHarnessEvent::ToolUse { name, detail } => HarnessEvent::ToolUse { name, detail },
            CoreHarnessEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                detail,
            } => HarnessEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                detail,
            },
            CoreHarnessEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            } => HarnessEvent::ControlResult {
                action,
                ok,
                detail,
                value,
            },
            CoreHarnessEvent::PermissionRequest {
                id,
                name,
                kind,
                detail,
            } => HarnessEvent::PermissionRequest {
                id,
                name,
                kind,
                detail,
            },
            CoreHarnessEvent::Notification { message } => HarnessEvent::Notification(message),
            CoreHarnessEvent::RuntimeError { message } => HarnessEvent::RuntimeError(message),
            CoreHarnessEvent::Ended { exit_code } => HarnessEvent::Ended { exit_code },
        }
    }
}

/// The Claude adapter's published state.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreClaudeSnapshot {
    pub state: CoreHarnessState,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    pub total_cost_usd: f64,
}

impl From<ClaudeSnapshot> for CoreClaudeSnapshot {
    fn from(snapshot: ClaudeSnapshot) -> Self {
        CoreClaudeSnapshot {
            state: snapshot.state.into(),
            session_id: snapshot.session_id,
            model_name: snapshot.model_name,
            total_cost_usd: snapshot.total_cost_usd,
        }
    }
}

/// What the Claude adapter asks the platform to do, case for case with
/// `powerup_core::harness::claude::adapter::ClaudeAdapterEffect`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreClaudeEffect {
    Publish {
        snapshot: CoreClaudeSnapshot,
    },
    ResolveBinary {
        generation: u64,
        binary_path_override: Option<String>,
    },
    Spawn {
        generation: u64,
        executable: String,
        arguments: Vec<String>,
        project_dir: String,
    },
    WriteStdin {
        line: Vec<u8>,
    },
    CloseStdin,
    TerminateAfterGrace {
        seconds: f64,
    },
    Emit {
        event: CoreHarnessEvent,
    },
}

impl From<ClaudeAdapterEffect> for CoreClaudeEffect {
    fn from(effect: ClaudeAdapterEffect) -> Self {
        match effect {
            ClaudeAdapterEffect::Publish(snapshot) => CoreClaudeEffect::Publish {
                snapshot: snapshot.into(),
            },
            ClaudeAdapterEffect::ResolveBinary {
                generation,
                binary_path_override,
            } => CoreClaudeEffect::ResolveBinary {
                generation,
                binary_path_override,
            },
            ClaudeAdapterEffect::Spawn {
                generation,
                executable,
                arguments,
                project_dir,
            } => CoreClaudeEffect::Spawn {
                generation,
                executable,
                arguments,
                project_dir,
            },
            ClaudeAdapterEffect::WriteStdin(line) => CoreClaudeEffect::WriteStdin { line },
            ClaudeAdapterEffect::CloseStdin => CoreClaudeEffect::CloseStdin,
            ClaudeAdapterEffect::TerminateAfterGrace { seconds } => {
                CoreClaudeEffect::TerminateAfterGrace { seconds }
            }
            ClaudeAdapterEffect::Emit(event) => CoreClaudeEffect::Emit {
                event: event.into(),
            },
        }
    }
}

fn converted(effects: Vec<ClaudeAdapterEffect>) -> Vec<CoreClaudeEffect> {
    effects.into_iter().map(Into::into).collect()
}

/// The Claude adapter's events in the normalized vocabulary (HK-090).
#[uniffi::export]
pub fn harness_event_from_claude(
    event: CoreClaudeEvent,
) -> Result<CoreHarnessEvent, CoreBridgeError> {
    contain(|| Ok(HarnessEvent::from_claude(event.into()).into()))
}

/// The argv of one launch (`launch::launch_arguments`, HK-077, HK-080).
#[uniffi::export]
pub fn claude_launch_arguments(
    model: String,
    permission_mode: String,
    effort: String,
    resume_session_id: Option<String>,
) -> Result<Vec<String>, CoreBridgeError> {
    contain(|| {
        Ok(launch::launch_arguments(
            &model,
            &permission_mode,
            &effort,
            resume_session_id.as_deref(),
        ))
    })
}

/// The user-turn line, newline included; none when the trimmed text is
/// empty (`stdin::user_turn_line`, HK-069).
#[uniffi::export]
pub fn claude_user_turn_line(text: String) -> Result<Option<Vec<u8>>, CoreBridgeError> {
    contain(|| stdin::user_turn_line(&text))
}

/// The control-request line, newline included, always in the nested
/// envelope (`stdin::control_request_line`, HK-067). `subtype` is
/// `interrupt`, `set_model` or `set_permission_mode`; the last two take
/// `value`, trimmed, and give none when it trims to nothing (HK-068). Any
/// other subtype fails: the adapter builds its own requests, so only tests
/// call this.
#[uniffi::export]
pub fn claude_control_request_line(
    request_id: String,
    subtype: String,
    value: Option<String>,
) -> Result<Option<Vec<u8>>, CoreBridgeError> {
    contain(|| {
        let value = value.unwrap_or_default();
        let request = match subtype.as_str() {
            "interrupt" => Some(ControlRequest::Interrupt),
            "set_model" => ControlRequest::set_model(&value),
            "set_permission_mode" => ControlRequest::set_permission_mode(&value),
            other => {
                return Err(CoreError::Failed {
                    message: format!("no control request has the subtype {other:?}"),
                })
            }
        };
        request
            .map(|request| stdin::control_request_line(&request_id, &request))
            .transpose()
    })
}

/// The Claude adapter's process rules (`adapter::ClaudeAdapter`). Swift
/// creates one per `ClaudeService` and keeps it across launches; the launch
/// generation lives inside. Every call returns effects for Swift to run in
/// order before the next call. It is called on the main actor; the lock
/// only keeps the object sound.
#[derive(Debug, uniffi::Object)]
pub struct CoreClaudeAdapter {
    adapter: Mutex<ClaudeAdapter>,
}

impl CoreClaudeAdapter {
    fn run(
        &self,
        call: impl FnOnce(&mut ClaudeAdapter) -> Vec<ClaudeAdapterEffect>,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        contain(|| Ok(converted(call(&mut locked(&self.adapter)))))
    }
}

#[uniffi::export]
impl CoreClaudeAdapter {
    /// A stopped adapter whose request ids are `"<prefix>-<n>"` (HK-396).
    #[uniffi::constructor]
    pub fn new(request_id_prefix: String) -> Result<Arc<Self>, CoreBridgeError> {
        contain(|| {
            Ok(Arc::new(CoreClaudeAdapter {
                adapter: Mutex::new(ClaudeAdapter::new(request_id_prefix)),
            }))
        })
    }

    /// The current launch's generation.
    pub fn generation(&self) -> Result<u64, CoreBridgeError> {
        contain(|| Ok(locked(&self.adapter).generation()))
    }

    /// The published state as it is now.
    pub fn snapshot(&self) -> Result<CoreClaudeSnapshot, CoreBridgeError> {
        contain(|| Ok(locked(&self.adapter).snapshot().into()))
    }

    pub fn start(
        &self,
        configuration: CoreHarnessConfiguration,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        let configuration = HarnessConfiguration::from(configuration);
        self.run(|adapter| adapter.start(&configuration))
    }

    pub fn binary_resolved(
        &self,
        generation: u64,
        path: Option<String>,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.binary_resolved(generation, path))
    }

    pub fn spawned(&self, generation: u64) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.spawned(generation))
    }

    pub fn spawn_failed(
        &self,
        generation: u64,
        executable: String,
        description: String,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.spawn_failed(generation, &executable, &description))
    }

    pub fn send(
        &self,
        text: String,
        process_running: bool,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.send(&text, process_running))
    }

    pub fn interrupt(
        &self,
        process_running: bool,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.interrupt(process_running))
    }

    pub fn set_model(
        &self,
        model: String,
        process_running: bool,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.set_model(&model, process_running))
    }

    pub fn set_permission_mode(
        &self,
        mode: String,
        process_running: bool,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.set_permission_mode(&mode, process_running))
    }

    pub fn stop(&self) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(ClaudeAdapter::stop)
    }

    /// One parsed stdout event of `generation`, fed one at a time.
    pub fn stdout_event(
        &self,
        generation: u64,
        event: CoreClaudeEvent,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        let event = ClaudeEvent::from(event);
        self.run(|adapter| adapter.stdout_event(generation, event))
    }

    /// The process of `generation` exited; its last stdout events were fed
    /// first.
    pub fn terminated(
        &self,
        generation: u64,
        exit_code: i32,
        clean: bool,
        stderr_tail: String,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.terminated(generation, exit_code, clean, &stderr_tail))
    }

    pub fn stdin_write_failed(
        &self,
        description: String,
    ) -> Result<Vec<CoreClaudeEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.stdin_write_failed(&description))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_claude_event_round_trips_through_the_bridge_type() {
        let every = [
            ClaudeEvent::Ready {
                session_id: "s".to_string(),
                model: "m".to_string(),
            },
            ClaudeEvent::TextDelta("Hel".to_string()),
            ClaudeEvent::AssistantMessage("Hello".to_string()),
            ClaudeEvent::ToolUse {
                name: "Edit".to_string(),
                detail: "a.txt".to_string(),
            },
            ClaudeEvent::TurnCompleted {
                result_text: Some("Done.".to_string()),
                cost_usd: Some(0.5),
                is_error: false,
                subtype: "success".to_string(),
            },
            ClaudeEvent::TurnCompleted {
                result_text: None,
                cost_usd: None,
                is_error: true,
                subtype: "error_during_execution".to_string(),
            },
            ClaudeEvent::ControlResult {
                action: "set_model".to_string(),
                ok: true,
                detail: String::new(),
                value: Some("sonnet".to_string()),
            },
            ClaudeEvent::ProcessError("boom".to_string()),
            ClaudeEvent::Terminated { exit_code: 1 },
        ];
        for event in every {
            assert_eq!(
                ClaudeEvent::from(CoreClaudeEvent::from(event.clone())),
                event
            );
        }
    }

    #[test]
    fn every_harness_event_round_trips_through_the_bridge_type() {
        let every = [
            HarnessEvent::SessionReady {
                session_id: "s".to_string(),
                model: "m".to_string(),
            },
            HarnessEvent::ReplyDelta("Hel".to_string()),
            HarnessEvent::Reply("Hello".to_string()),
            HarnessEvent::ToolUse {
                name: "Bash".to_string(),
                detail: "ls".to_string(),
            },
            HarnessEvent::TurnCompleted {
                result_text: None,
                cost_usd: Some(0.25),
                is_error: true,
                detail: "error_max_turns".to_string(),
            },
            HarnessEvent::ControlResult {
                action: "interrupt".to_string(),
                ok: false,
                detail: "no turn".to_string(),
                value: None,
            },
            HarnessEvent::PermissionRequest {
                id: "p1".to_string(),
                name: "rm -rf build".to_string(),
                kind: "execute".to_string(),
                detail: "rm -rf build".to_string(),
            },
            HarnessEvent::Notification("Waiting".to_string()),
            HarnessEvent::RuntimeError("boom".to_string()),
            HarnessEvent::Ended { exit_code: -1 },
        ];
        for event in every {
            assert_eq!(
                HarnessEvent::from(CoreHarnessEvent::from(event.clone())),
                event
            );
        }
        for state in [
            HarnessState::Stopped,
            HarnessState::Starting,
            HarnessState::Ready,
            HarnessState::Working,
        ] {
            assert_eq!(HarnessState::from(CoreHarnessState::from(state)), state);
        }
    }

    #[test]
    fn a_claude_event_normalizes_through_the_bridge() {
        assert_eq!(
            harness_event_from_claude(CoreClaudeEvent::ProcessError {
                message: "boom".to_string()
            }),
            Ok(CoreHarnessEvent::RuntimeError {
                message: "boom".to_string()
            })
        );
    }

    #[test]
    fn stdin_lines_come_from_the_core() {
        let line = |bytes: Option<Vec<u8>>| bytes.map(|b| String::from_utf8(b).unwrap());
        assert_eq!(
            claude_control_request_line("R-1".to_string(), "set_model".to_string(), Some(" sonnet ".to_string()))
                .map(line),
            Ok(Some(
                "{\"type\":\"control_request\",\"request_id\":\"R-1\",\"request\":{\"subtype\":\"set_model\",\"model\":\"sonnet\"}}\n"
                    .to_string()
            ))
        );
        assert_eq!(
            claude_control_request_line("R-2".to_string(), "set_model".to_string(), None),
            Ok(None)
        );
        assert!(matches!(
            claude_control_request_line(
                "R-3".to_string(),
                "set_effort".to_string(),
                Some("low".to_string())
            ),
            Err(CoreBridgeError::Failed { .. })
        ));
        assert_eq!(claude_user_turn_line("  ".to_string()), Ok(None));
        assert!(claude_user_turn_line(" Hi ".to_string())
            .unwrap()
            .is_some_and(|bytes| bytes.ends_with(b"\n")));
        assert_eq!(
            claude_launch_arguments(
                "default".to_string(),
                String::new(),
                "default".to_string(),
                Some(" s ".to_string())
            )
            .unwrap()
            .last(),
            Some(&"s".to_string())
        );
    }

    #[test]
    fn the_adapter_object_runs_the_core_rules() {
        let adapter = CoreClaudeAdapter::new("R".to_string()).unwrap();
        let effects = adapter
            .start(CoreHarnessConfiguration {
                project_dir: "/work/app".to_string(),
                model: "default".to_string(),
                permission_mode: "acceptEdits".to_string(),
                effort: "default".to_string(),
                resume_session_id: Some("s-1".to_string()),
                binary_path_override: None,
                agent_command: None,
            })
            .unwrap();
        assert_eq!(
            effects,
            vec![
                CoreClaudeEffect::Publish {
                    snapshot: CoreClaudeSnapshot {
                        state: CoreHarnessState::Starting,
                        session_id: Some("s-1".to_string()),
                        model_name: None,
                        total_cost_usd: 0.0,
                    }
                },
                CoreClaudeEffect::ResolveBinary {
                    generation: 1,
                    binary_path_override: None,
                },
            ]
        );
        assert_eq!(adapter.generation(), Ok(1));
        // A send while the binary resolves is queued and flushed on spawn.
        assert_eq!(adapter.send("Hi".to_string(), false).unwrap().len(), 1);
        assert!(matches!(
            adapter
                .binary_resolved(1, Some("/bin/claude".to_string()))
                .unwrap()
                .as_slice(),
            [CoreClaudeEffect::Spawn { generation: 1, .. }]
        ));
        assert!(matches!(
            adapter.spawned(1).unwrap().as_slice(),
            [CoreClaudeEffect::WriteStdin { .. }]
        ));
        let init = br#"{"type":"system","subtype":"init","session_id":"s-1","model":"m"}"#;
        let event = claude_events_from_line(init.to_vec()).unwrap().remove(0);
        assert!(matches!(
            adapter.stdout_event(1, event).unwrap().as_slice(),
            [
                CoreClaudeEffect::Publish { .. },
                CoreClaudeEffect::Emit {
                    event: CoreHarnessEvent::SessionReady { .. }
                }
            ]
        ));
        assert_eq!(adapter.snapshot().unwrap().state, CoreHarnessState::Working);
    }

    #[test]
    fn a_line_parses_like_the_core() {
        let line = br#"{"type":"system","subtype":"init","session_id":"s","model":"m"}"#;
        assert_eq!(
            claude_events_from_line(line.to_vec()),
            Ok(vec![CoreClaudeEvent::Ready {
                session_id: "s".to_string(),
                model: "m".to_string(),
            }])
        );
        assert_eq!(claude_events_from_line(b"not json".to_vec()), Ok(vec![]));
    }

    #[test]
    fn the_line_buffer_keeps_its_tail_between_calls() {
        let buffer = CoreLineBuffer::new().unwrap();
        assert_eq!(buffer.ingest(b"{\"a\"".to_vec()), Ok(vec![]));
        assert_eq!(
            buffer.ingest(b":1}\n\n{\"b\"".to_vec()),
            Ok(vec![b"{\"a\":1}".to_vec()])
        );
        assert_eq!(buffer.flush_remainder(), Ok(Some(b"{\"b\"".to_vec())));
        assert_eq!(buffer.flush_remainder(), Ok(None));
    }
}
