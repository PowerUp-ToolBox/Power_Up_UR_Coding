//! What a `session/update` tool call shows (HK-149, HK-150): a short name
//! and a short detail for the transcript, the spoken status and the
//! destructive-action classifier.

use crate::harness::json::JsonValue;
use crate::text;

/// The rawInput keys tried for a detail, in order. Claude's list also has
/// "prompt"; ACP's does not.
pub(crate) const TOOL_DETAIL_KEYS: [&str; 5] =
    ["file_path", "command", "description", "pattern", "url"];

/// A rawInput detail above this many clusters keeps one fewer and gains
/// "…".
pub(crate) const TOOL_DETAIL_MAX: usize = 80;

/// The best short detail of a tool call (HK-150): the last path component
/// of the FIRST location's non-empty `path` (the locations must all be
/// objects, Swift's all-or-nothing `[[String: Any]]` cast, and a later
/// location is never tried), else the first non-empty string among
/// rawInput's [`TOOL_DETAIL_KEYS`], cut to [`TOOL_DETAIL_MAX`] clusters,
/// else "". Nothing is condensed: newlines and tabs stay.
pub(crate) fn tool_detail(tool_call: Option<&JsonValue>) -> String {
    let Some(tool_call) = tool_call else {
        return String::new();
    };
    let first_path = tool_call
        .get("locations")
        .and_then(JsonValue::as_object_array)
        .and_then(|locations| locations.first().copied())
        .and_then(|location| location.get("path"))
        .and_then(JsonValue::as_str);
    if let Some(path) = first_path.filter(|path| !path.is_empty()) {
        return text::last_path_component(path).to_owned();
    }
    let Some(raw_input) = tool_call.get("rawInput") else {
        return String::new();
    };
    for key in TOOL_DETAIL_KEYS {
        let Some(value) = raw_input.get(key).and_then(JsonValue::as_str) else {
            continue;
        };
        if value.is_empty() {
            continue;
        }
        if text::grapheme_count(value) > TOOL_DETAIL_MAX {
            let mut cut = text::grapheme_prefix(value, TOOL_DETAIL_MAX - 1).to_owned();
            cut.push('…');
            return cut;
        }
        return value.to_owned();
    }
    String::new()
}

/// A tool call's name (HK-149): `_meta.claudeCode.toolName` when it is a
/// string (even an empty one; the Claude bridge's title is a long phrase),
/// else `title`, else "Tool".
pub(crate) fn tool_name(update: &JsonValue) -> String {
    update
        .get("_meta")
        .and_then(|meta| meta.get("claudeCode"))
        .and_then(|claude| claude.get("toolName"))
        .and_then(JsonValue::as_str)
        .or_else(|| update.get("title").and_then(JsonValue::as_str))
        .unwrap_or("Tool")
        .to_owned()
}
