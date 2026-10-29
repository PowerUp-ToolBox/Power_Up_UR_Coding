//! The JSON-RPC 2.0 lines the adapter writes (HK-153, HK-404): one compact
//! JSON object followed by `\n`, so a newline inside a prompt can never
//! split a message (JSON escapes it). The members come in a fixed order
//! (`jsonrpc`, `id`, `method`, `params` for a request, without `id` for a
//! notification, and `jsonrpc`, `id`, `result` or `error` for a response)
//! and strings are escaped as Swift
//! escapes them (`/` as `\/`). Swift's JSONSerialization wrote dictionary
//! order, which was never stable, and agents parse JSON, so the fixtures
//! compare these lines as JSON.

use crate::json::{self, JsonNumber, JsonValue};
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

/// `{"jsonrpc":"2.0","method":method,"params":params}` and a newline.
pub(crate) fn notification_line(method: &str, params: JsonValue) -> Result<Vec<u8>, CoreError> {
    line(obj(vec![
        ("jsonrpc", string("2.0")),
        ("method", string(method)),
        ("params", params),
    ]))
}

/// The id a response carries: one of ours, or the agent's own, echoed as it
/// was read (a string, a fraction, null, even an array), as Swift wrote the
/// `Any` it had read back.
#[derive(Debug, Clone, Copy)]
pub(crate) enum ResponseId<'a> {
    Ours(i64),
    Echo(&'a JsonValue),
}

/// JSON-RPC's "method not found".
pub(crate) const METHOD_NOT_FOUND: i64 = -32601;

/// `{"jsonrpc":"2.0","id":id,"result":result}` and a newline.
pub(crate) fn result_line(id: ResponseId<'_>, result: JsonValue) -> Result<Vec<u8>, CoreError> {
    response_line(id, "result", &result)
}

/// `{"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}` and
/// a newline.
pub(crate) fn error_line(
    id: ResponseId<'_>,
    code: i64,
    message: &str,
) -> Result<Vec<u8>, CoreError> {
    let error = obj(vec![("code", number(code)), ("message", string(message))]);
    response_line(id, "error", &error)
}

/// A response is written in pieces so an echoed id is written straight
/// from the parsed line: copying a deep id into a new tree would recurse.
fn response_line(id: ResponseId<'_>, key: &str, body: &JsonValue) -> Result<Vec<u8>, CoreError> {
    let id = match id {
        ResponseId::Ours(id) => json::write(&number(id))?,
        ResponseId::Echo(id) => json::write(id)?,
    };
    let key = json::write(&string(key))?;
    let body = json::write(body)?;
    let mut bytes = format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},{key}:{body}}}").into_bytes();
    bytes.push(b'\n');
    Ok(bytes)
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

pub(crate) fn number(value: i64) -> JsonValue {
    JsonValue::Number(JsonNumber::from_i64(value))
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
    fn an_echoed_id_is_written_as_read() {
        let cancelled = || {
            obj(vec![(
                "outcome",
                obj(vec![("outcome", string("cancelled"))]),
            )])
        };
        for (read, written) in [
            (r#""abc""#, r#""abc""#),
            ("1.5", "1.5"),
            ("2.50", "2.5"),
            ("null", "null"),
            (r#"[1,{"a":"/"}]"#, r#"[1,{"a":"\/"}]"#),
        ] {
            let message = json::read(format!(r#"{{"id":{read}}}"#).as_bytes()).unwrap();
            let echoed = message.get("id").unwrap();
            assert_eq!(
                text(result_line(ResponseId::Echo(echoed), cancelled()).unwrap()),
                format!(
                    "{{\"jsonrpc\":\"2.0\",\"id\":{written},\"result\":{{\"outcome\":{{\"outcome\":\"cancelled\"}}}}}}\n"
                )
            );
        }
        assert_eq!(
            text(error_line(ResponseId::Ours(7), METHOD_NOT_FOUND, "PowerUp does not support fs/read").unwrap()),
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"PowerUp does not support fs\\/read\"}}\n"
        );
        assert_eq!(
            text(notification_line("session/cancel", obj(vec![("sessionId", string("s1"))])).unwrap()),
            "{\"jsonrpc\":\"2.0\",\"method\":\"session\\/cancel\",\"params\":{\"sessionId\":\"s1\"}}\n"
        );
    }

    #[test]
    fn a_deep_echoed_id_is_written_without_the_call_stack() {
        let depth = 512;
        let line = format!("{{\"id\":{}{}}}", "[".repeat(depth), "]".repeat(depth));
        let written = std::thread::Builder::new()
            .stack_size(64 * 1024)
            .spawn(move || {
                let message = json::read(line.as_bytes()).unwrap();
                let id = message.get("id").unwrap();
                result_line(ResponseId::Echo(id), JsonValue::Null).unwrap()
            })
            .unwrap()
            .join()
            .unwrap();
        assert!(text(written).contains(&"[".repeat(depth)));
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
