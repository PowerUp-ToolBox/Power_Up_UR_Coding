//! What one stdout line of the claude CLI means, before the adapter applies
//! it: Swift's `ClaudeEvent`, case for case.

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
