//! What one stdout line of the claude CLI means, before the adapter applies
//! it: Swift's `ClaudeEvent`, case for case.

use crate::harness::HarnessEvent;

/// One event parsed from a stdout line.
#[derive(Debug, Clone, PartialEq)]
pub enum ClaudeEvent {
    /// system/init: the session id and the model the CLI reports.
    Ready { session_id: String, model: String },
    /// A stream_event text_delta: live reply text.
    TextDelta(String),
    /// The joined, trimmed text blocks of one assistant message.
    AssistantMessage(String),
    /// A tool_use block: the tool's name and a short detail of its input.
    ToolUse { name: String, detail: String },
    /// A result line: the turn ended.
    TurnCompleted {
        result_text: Option<String>,
        cost_usd: Option<f64>,
        is_error: bool,
        subtype: String,
    },
    /// A control_response. At the parse layer `action` carries the raw
    /// request_id and `value` is `None`; the adapter swaps in the subtype and
    /// value it recorded when the request went out (HK-070).
    ControlResult {
        action: String,
        ok: bool,
        detail: String,
        value: Option<String>,
    },
    /// stderr text or a spawn failure; never parsed from a line.
    ProcessError(String),
    /// The process exited; never parsed from a line.
    Terminated { exit_code: i32 },
}

impl HarnessEvent {
    /// The Claude adapter's events in the normalized vocabulary. Total and
    /// one to one (HK-090): a result's subtype becomes the detail, a process
    /// error a runtime error, and an exit `Ended`. The adapter never makes a
    /// permission request or a notification.
    pub fn from_claude(event: ClaudeEvent) -> HarnessEvent {
        match event {
            ClaudeEvent::Ready { session_id, model } => {
                HarnessEvent::SessionReady { session_id, model }
            }
            ClaudeEvent::TextDelta(text) => HarnessEvent::ReplyDelta(text),
            ClaudeEvent::AssistantMessage(text) => HarnessEvent::Reply(text),
            ClaudeEvent::ToolUse { name, detail } => HarnessEvent::ToolUse { name, detail },
            ClaudeEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                subtype,
            } => HarnessEvent::TurnCompleted {
                result_text,
                cost_usd,
                is_error,
                detail: subtype,
            },
            ClaudeEvent::ControlResult {
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
            ClaudeEvent::ProcessError(message) => HarnessEvent::RuntimeError(message),
            ClaudeEvent::Terminated { exit_code } => HarnessEvent::Ended { exit_code },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_claude_event_has_one_harness_event() {
        let pairs = [
            (
                ClaudeEvent::Ready {
                    session_id: "s".into(),
                    model: "m".into(),
                },
                HarnessEvent::SessionReady {
                    session_id: "s".into(),
                    model: "m".into(),
                },
            ),
            (
                ClaudeEvent::TextDelta("d".into()),
                HarnessEvent::ReplyDelta("d".into()),
            ),
            (
                ClaudeEvent::AssistantMessage("a".into()),
                HarnessEvent::Reply("a".into()),
            ),
            (
                ClaudeEvent::ToolUse {
                    name: "Read".into(),
                    detail: "/a".into(),
                },
                HarnessEvent::ToolUse {
                    name: "Read".into(),
                    detail: "/a".into(),
                },
            ),
            (
                ClaudeEvent::TurnCompleted {
                    result_text: Some("r".into()),
                    cost_usd: Some(0.5),
                    is_error: true,
                    subtype: "error_max_turns".into(),
                },
                HarnessEvent::TurnCompleted {
                    result_text: Some("r".into()),
                    cost_usd: Some(0.5),
                    is_error: true,
                    detail: "error_max_turns".into(),
                },
            ),
            (
                ClaudeEvent::ControlResult {
                    action: "set_model".into(),
                    ok: false,
                    detail: "no".into(),
                    value: Some("opus".into()),
                },
                HarnessEvent::ControlResult {
                    action: "set_model".into(),
                    ok: false,
                    detail: "no".into(),
                    value: Some("opus".into()),
                },
            ),
            (
                ClaudeEvent::ProcessError("boom".into()),
                HarnessEvent::RuntimeError("boom".into()),
            ),
            (
                ClaudeEvent::Terminated { exit_code: -1 },
                HarnessEvent::Ended { exit_code: -1 },
            ),
        ];
        for (claude, harness) in pairs {
            // The match below is exhaustive, so a new ClaudeEvent case fails
            // to compile until it is added to this table.
            match &claude {
                ClaudeEvent::Ready { .. }
                | ClaudeEvent::TextDelta(_)
                | ClaudeEvent::AssistantMessage(_)
                | ClaudeEvent::ToolUse { .. }
                | ClaudeEvent::TurnCompleted { .. }
                | ClaudeEvent::ControlResult { .. }
                | ClaudeEvent::ProcessError(_)
                | ClaudeEvent::Terminated { .. } => {}
            }
            assert_eq!(HarnessEvent::from_claude(claude), harness);
        }
    }
}
