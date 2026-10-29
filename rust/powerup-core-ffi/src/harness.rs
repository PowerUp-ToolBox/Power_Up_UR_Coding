//! The Claude harness half of slice 2.3: the stdout line buffer and the
//! stream-json line parser.
//!
//! As in `mapping`, the types are the uniffi faces of their `powerup-core`
//! twins with a `Core` prefix (DESIGN v2.12 A), converted both ways with
//! exhaustive matches. `CoreLineBuffer` is the first object across the
//! bridge: Swift owns it (one per launch's pipe), and it never calls back.

use std::sync::{Arc, Mutex};

use powerup_core::harness::claude::event::ClaudeEvent;
use powerup_core::harness::claude::lines::LineBuffer;
use powerup_core::harness::claude::parse;

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
