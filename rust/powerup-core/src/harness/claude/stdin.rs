//! The lines the platform writes on the claude CLI's stdin (DESIGN.md
//! v1.1 A, verified live against claude CLI v2.1.243): user turns and
//! control requests, one compact JSON object and a newline each.
//!
//! Keys come out in a fixed order (HK-395): `type`, `message`,
//! `parent_tool_use_id` for a turn, and `type`, `request_id`, `request`
//! with `subtype` first inside it for a control request. Swift's
//! JSONSerialization wrote them in hash order, so no byte order was ever
//! stable; the CLI parses JSON, and the fixtures compare the lines as JSON.
//! Strings are escaped as Swift's encoder escapes them (`wire`).

use serde::Serialize;

use crate::{text, wire, CoreError};

/// A control request the app sends while a session runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlRequest {
    /// Stops the current turn; carries no value.
    Interrupt,
    /// Switches the model live, without a restart; carries `model`.
    SetModel(String),
    /// Switches the permission mode live; carries `mode`.
    SetPermissionMode(String),
}

impl ControlRequest {
    /// set_model with the trimmed model; `None` when it trims to nothing,
    /// because an empty value sends no request (HK-068).
    pub fn set_model(model: &str) -> Option<ControlRequest> {
        let model = text::trim(model);
        (!model.is_empty()).then(|| ControlRequest::SetModel(model.to_owned()))
    }

    /// set_permission_mode with the trimmed mode; `None` when it trims to
    /// nothing (HK-068).
    pub fn set_permission_mode(mode: &str) -> Option<ControlRequest> {
        let mode = text::trim(mode);
        (!mode.is_empty()).then(|| ControlRequest::SetPermissionMode(mode.to_owned()))
    }

    /// The wire subtype. There is no live effort switch: set_effort does not
    /// exist (verified live, the CLI answers it with an error and keeps
    /// running), so effort changes restart the session instead.
    pub fn subtype(&self) -> &'static str {
        match self {
            ControlRequest::Interrupt => "interrupt",
            ControlRequest::SetModel(_) => "set_model",
            ControlRequest::SetPermissionMode(_) => "set_permission_mode",
        }
    }

    /// The value the request asks for: the model or the mode.
    pub fn value(&self) -> Option<&str> {
        match self {
            ControlRequest::Interrupt => None,
            ControlRequest::SetModel(value) | ControlRequest::SetPermissionMode(value) => {
                Some(value)
            }
        }
    }
}

#[derive(Serialize)]
struct UserTurn<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    message: UserMessage<'a>,
    parent_tool_use_id: Option<&'a str>,
}

#[derive(Serialize)]
struct UserMessage<'a> {
    role: &'static str,
    content: [TextBlock<'a>; 1],
}

#[derive(Serialize)]
struct TextBlock<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    text: &'a str,
}

#[derive(Serialize)]
struct ControlEnvelope<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    request_id: &'a str,
    request: RequestBody<'a>,
}

#[derive(Serialize)]
struct RequestBody<'a> {
    subtype: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mode: Option<&'a str>,
}

fn line<T: Serialize>(value: &T) -> Result<Vec<u8>, CoreError> {
    let mut bytes = wire::to_swift_json(value)?.into_bytes();
    bytes.push(b'\n');
    Ok(bytes)
}

/// The user-turn line (HK-069): `{"type":"user","message":{"role":"user",
/// "content":[{"type":"text","text":…}]},"parent_tool_use_id":null}` and a
/// newline, with the text trimmed at both ends only. `None` when nothing is
/// left, so nothing is sent.
pub fn user_turn_line(text: &str) -> Result<Option<Vec<u8>>, CoreError> {
    let text = text::trim(text);
    if text.is_empty() {
        return Ok(None);
    }
    line(&UserTurn {
        kind: "user",
        message: UserMessage {
            role: "user",
            content: [TextBlock { kind: "text", text }],
        },
        parent_tool_use_id: None,
    })
    .map(Some)
}

/// The control-request line (HK-067): always the nested envelope
/// `{"type":"control_request","request_id":…,"request":{"subtype":…}}` and
/// a newline. The flat shape `{"type":"control_request","subtype":…}` is
/// fatal: verified live, the CLI exits 1 with "Missing request on
/// control_request" and the session dies. Any unique string works as the
/// request id.
pub fn control_request_line(
    request_id: &str,
    request: &ControlRequest,
) -> Result<Vec<u8>, CoreError> {
    let (model, mode) = match request {
        ControlRequest::Interrupt => (None, None),
        ControlRequest::SetModel(model) => (Some(model.as_str()), None),
        ControlRequest::SetPermissionMode(mode) => (None, Some(mode.as_str())),
    };
    line(&ControlEnvelope {
        kind: "control_request",
        request_id,
        request: RequestBody {
            subtype: request.subtype(),
            model,
            mode,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(bytes: Vec<u8>) -> String {
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn user_turn_bytes_are_pinned() {
        let line = user_turn_line("  a/b \"c\"\n修复 🚀 ").unwrap().unwrap();
        assert_eq!(
            text(line),
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\
             \"text\":\"a\\/b \\\"c\\\"\\n修复 🚀\"}]},\"parent_tool_use_id\":null}\n"
        );
        assert_eq!(user_turn_line(" \n\t").unwrap(), None);
    }

    #[test]
    fn control_request_bytes_are_pinned() {
        let interrupt = control_request_line("R-1", &ControlRequest::Interrupt).unwrap();
        assert_eq!(
            text(interrupt),
            "{\"type\":\"control_request\",\"request_id\":\"R-1\",\"request\":{\"subtype\":\"interrupt\"}}\n"
        );
        let model = ControlRequest::set_model(" sonnet\n").unwrap();
        assert_eq!(
            text(control_request_line("R-2", &model).unwrap()),
            "{\"type\":\"control_request\",\"request_id\":\"R-2\",\"request\":{\"subtype\":\"set_model\",\"model\":\"sonnet\"}}\n"
        );
        let mode = ControlRequest::set_permission_mode("plan").unwrap();
        assert_eq!(
            text(control_request_line("R-3", &mode).unwrap()),
            "{\"type\":\"control_request\",\"request_id\":\"R-3\",\"request\":{\"subtype\":\"set_permission_mode\",\"mode\":\"plan\"}}\n"
        );
        assert_eq!(ControlRequest::set_model("  "), None);
        assert_eq!(ControlRequest::set_permission_mode(""), None);
    }

    #[test]
    fn the_flat_control_request_shape_is_never_written() {
        let requests = [
            ControlRequest::Interrupt,
            ControlRequest::SetModel("opus".into()),
            ControlRequest::SetPermissionMode("plan".into()),
        ];
        for request in &requests {
            let line = text(control_request_line("R-1", request).unwrap());
            assert!(line.contains("\"request\":{\"subtype\":"), "{line}");
            assert!(!line.contains("\"control_request\",\"subtype\""), "{line}");
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert!(value.get("subtype").is_none(), "{line}");
            assert_eq!(value["request"]["subtype"], request.subtype());
        }
    }
}
