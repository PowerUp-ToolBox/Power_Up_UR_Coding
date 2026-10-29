//! One stdout line of the claude CLI's stream-json output into events
//! (HK-054 to HK-065, HK-072), exactly as `ClaudeService.events(fromLine:)`
//! reads it. Anything unrecognized gives no events: the CLI adds message
//! types across versions, and a field of the wrong type reads as missing.

use super::event::ClaudeEvent;
use super::json::{self, JsonValue};
use crate::text;

/// Tried in this order for a tool's detail, before any other key (HK-061).
const PREFERRED_DETAIL_KEYS: [&str; 6] = [
    "file_path",
    "command",
    "description",
    "pattern",
    "url",
    "prompt",
];
/// Clusters of tool detail (HK-062).
const TOOL_DETAIL_MAX: usize = 80;
/// Clusters of a control error's detail (HK-072).
const CONTROL_ERROR_MAX: usize = 200;

/// The events one line (without its newline) gives; `[]` for anything
/// unrecognized.
pub fn events_from_line(line: &[u8]) -> Vec<ClaudeEvent> {
    if line.is_empty() {
        return Vec::new();
    }
    let Some(root) = json::read(line) else {
        return Vec::new();
    };
    let Some(kind) = root.get("type").and_then(JsonValue::as_str) else {
        return Vec::new();
    };
    match kind {
        "system" => system_events(&root),
        "stream_event" => text_delta(&root).into_iter().collect(),
        "assistant" => assistant_events(&root),
        "control_response" => control_response(&root).into_iter().collect(),
        // Echoes of our own turns, plus CLI notes such as the
        // "<local-command-stdout>Set model to …" line after set_model, whose
        // content is a plain string. Nothing here is read (HK-057).
        "user" => Vec::new(),
        "result" => vec![turn_completed(&root)],
        // rate_limit_event, and anything a later CLI adds (HK-054).
        _ => Vec::new(),
    }
}

fn string_field<'a>(value: &'a JsonValue, key: &str) -> Option<&'a str> {
    value.get(key).and_then(JsonValue::as_str)
}

/// Only system/init means anything, and only with a session id (HK-055).
fn system_events(root: &JsonValue) -> Vec<ClaudeEvent> {
    if string_field(root, "subtype") != Some("init") {
        return Vec::new();
    }
    let session_id = string_field(root, "session_id").unwrap_or_default();
    if session_id.is_empty() {
        return Vec::new();
    }
    vec![ClaudeEvent::Ready {
        session_id: session_id.to_owned(),
        model: string_field(root, "model").unwrap_or_default().to_owned(),
    }]
}

/// Only a content_block_delta's non-empty text_delta is reply text; thinking,
/// signature and input_json deltas are never shown or spoken (HK-056).
fn text_delta(root: &JsonValue) -> Option<ClaudeEvent> {
    let event = root.get("event")?;
    event.as_object()?;
    if string_field(event, "type") != Some("content_block_delta") {
        return None;
    }
    let delta = event.get("delta")?;
    delta.as_object()?;
    if string_field(delta, "type") != Some("text_delta") {
        return None;
    }
    let text = string_field(delta, "text")?;
    (!text.is_empty()).then(|| ClaudeEvent::TextDelta(text.to_owned()))
}

/// An assistant message, whose content is a string (seen after set_model,
/// HK-058) or a list of blocks: text blocks are trimmed, dropped when
/// empty and joined with a newline; tool_use blocks give tool events after
/// the text (HK-060); thinking, redacted_thinking, tool_result and anything
/// else are skipped (HK-059). The CLI repeats a message once per completed
/// content block; dropping the repeat is the adapter's job (HK-074).
fn assistant_events(root: &JsonValue) -> Vec<ClaudeEvent> {
    let Some(message) = root.get("message").filter(|m| m.as_object().is_some()) else {
        return Vec::new();
    };
    let content = message.get("content");
    if let Some(plain) = content.and_then(JsonValue::as_str) {
        let trimmed = text::trim(plain);
        return if trimmed.is_empty() {
            Vec::new()
        } else {
            vec![ClaudeEvent::AssistantMessage(trimmed.to_owned())]
        };
    }
    let Some(blocks) = content.and_then(JsonValue::as_array) else {
        return Vec::new();
    };
    let mut texts: Vec<&str> = Vec::new();
    let mut tools: Vec<ClaudeEvent> = Vec::new();
    for block in blocks {
        if block.as_object().is_none() {
            continue;
        }
        match string_field(block, "type") {
            Some("text") => {
                if let Some(text) = string_field(block, "text") {
                    let trimmed = text::trim(text);
                    if !trimmed.is_empty() {
                        texts.push(trimmed);
                    }
                }
            }
            Some("tool_use") => tools.push(ClaudeEvent::ToolUse {
                name: string_field(block, "name").unwrap_or("Tool").to_owned(),
                detail: tool_detail(block.get("input")),
            }),
            _ => {}
        }
    }
    let mut events = Vec::with_capacity(tools.len() + 1);
    if !texts.is_empty() {
        events.push(ClaudeEvent::AssistantMessage(texts.join("\n")));
    }
    events.extend(tools);
    events
}

/// A short, stable summary of a tool's input (HK-061): the first preferred
/// key whose string value condenses to something, else the first such
/// value by key name, else "". Keys sort by scalar value, which is Swift's
/// order for every key a tool sends (Swift orders by the NFC form). Of two
/// equal keys only the first exists, as in Swift's dictionary.
fn tool_detail(input: Option<&JsonValue>) -> String {
    let Some(members) = input.and_then(JsonValue::as_object) else {
        return String::new();
    };
    let detail_of = |key: &str| {
        let value = members.iter().find(|(name, _)| name == key)?.1.as_str()?;
        let condensed = text::condense(value, TOOL_DETAIL_MAX);
        (!condensed.is_empty()).then_some(condensed)
    };
    if let Some(detail) = PREFERRED_DETAIL_KEYS.iter().find_map(|key| detail_of(key)) {
        return detail;
    }
    let mut keys: Vec<&str> = members.iter().map(|(name, _)| name.as_str()).collect();
    keys.sort_unstable();
    keys.dedup();
    keys.into_iter().find_map(detail_of).unwrap_or_default()
}

/// `{"type":"control_response","response":{"subtype":…,"request_id":…}}`
/// (HK-070, HK-072). A failure's detail is response.error, else
/// response.response.error (the nesting varies by CLI version); an empty one
/// falls back to the subtype, or to a generic reason without one.
fn control_response(root: &JsonValue) -> Option<ClaudeEvent> {
    let response = root.get("response").filter(|r| r.as_object().is_some())?;
    let request_id = string_field(response, "request_id")?;
    if request_id.is_empty() {
        return None;
    }
    let subtype = string_field(response, "subtype").unwrap_or_default();
    let ok = subtype == "success";
    let mut detail = "";
    if !ok {
        detail = string_field(response, "error")
            .or_else(|| {
                let nested = response.get("response")?;
                nested.as_object()?;
                string_field(nested, "error")
            })
            .unwrap_or_default();
        if text::trim(detail).is_empty() {
            detail = if subtype.is_empty() {
                "the CLI rejected the request"
            } else {
                subtype
            };
        }
    }
    Some(ClaudeEvent::ControlResult {
        action: request_id.to_owned(),
        ok,
        detail: text::condense(detail, CONTROL_ERROR_MAX),
        value: None,
    })
}

/// A result line (HK-064, HK-065): an error when is_error reads true or the
/// subtype (default "success") is anything else; a whitespace result text is
/// none; the cost is any number, read through NSNumber (HK-394).
fn turn_completed(root: &JsonValue) -> ClaudeEvent {
    let subtype = string_field(root, "subtype").unwrap_or("success");
    let flagged = root
        .get("is_error")
        .and_then(JsonValue::as_swift_bool)
        .unwrap_or(false);
    let result_text = string_field(root, "result")
        .map(text::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned);
    ClaudeEvent::TurnCompleted {
        result_text,
        cost_usd: root
            .get("total_cost_usd")
            .and_then(JsonValue::as_swift_number),
        is_error: flagged || subtype != "success",
        subtype: subtype.to_owned(),
    }
}
