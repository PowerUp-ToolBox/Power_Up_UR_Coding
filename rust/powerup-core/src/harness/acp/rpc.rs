//! The JSON-RPC 2.0 lines the adapter writes (HK-153, HK-404): one compact
//! JSON object followed by `\n`, so a newline inside a prompt can never
//! split a message (JSON escapes it). The members come in a fixed order
//! (`jsonrpc`, `id`, `method`, `params`) and strings are escaped as Swift
//! escapes them (`/` as `\/`). Swift's JSONSerialization wrote dictionary
//! order, which was never stable, and agents parse JSON, so the fixtures
//! compare these lines as JSON.

use crate::harness::json::{self, JsonValue};
use crate::CoreError;

/// `{"jsonrpc":"2.0","id":id,"method":method,"params":params}` and a
/// newline.
pub(crate) fn request_line(id: i64, method: &str, params: JsonValue) -> Result<Vec<u8>, CoreError> {
    line(obj(vec![
        ("jsonrpc", string("2.0")),
        ("id", number(id)),
        ("method", string(method)),
        ("params", params),
    ]))
}

fn line(message: JsonValue) -> Result<Vec<u8>, CoreError> {
    let mut bytes = json::write(&message)?.into_bytes();
    bytes.push(b'\n');
    Ok(bytes)
}

/// An object with these members, in this order.
pub(crate) fn obj(members: Vec<(&str, JsonValue)>) -> JsonValue {
    JsonValue::Object(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

pub(crate) fn string(text: &str) -> JsonValue {
    JsonValue::String(text.to_owned())
}

/// Our ids and codes are far below 2^53, so the double holds them exactly.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn number(value: i64) -> JsonValue {
    JsonValue::Number(value as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(bytes: Vec<u8>) -> String {
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn initialize_bytes_are_pinned() {
        let params = obj(vec![
            ("protocolVersion", number(1)),
            (
                "clientCapabilities",
                obj(vec![(
                    "fs",
                    obj(vec![
                        ("readTextFile", JsonValue::Bool(false)),
                        ("writeTextFile", JsonValue::Bool(false)),
                    ]),
                )]),
            ),
        ]);
        assert_eq!(
            text(request_line(1, "initialize", params).unwrap()),
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false}}}}\n"
        );
    }

    #[test]
    fn every_line_is_one_line() {
        let params = obj(vec![
            ("sessionId", string("s/1")),
            (
                "prompt",
                JsonValue::Array(vec![obj(vec![
                    ("type", string("text")),
                    ("text", string("two\nlines\r\u{2028}end")),
                ])]),
            ),
        ]);
        let line = text(request_line(7, "session/prompt", params).unwrap());
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        assert!(!line.contains('\r'));
        assert_eq!(
            line,
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session\\/prompt\",\"params\":{\"sessionId\":\"s\\/1\",\"prompt\":[{\"type\":\"text\",\"text\":\"two\\nlines\\r\u{2028}end\"}]}}\n"
        );
    }
}
