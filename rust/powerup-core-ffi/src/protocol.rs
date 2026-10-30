//! The PowerUp protocol's pure half of slice 2.6: how a client's text frame
//! reads, the protocol name table, every server message as the text of its
//! frame, the handshake a request head comes to, the accept key and the
//! RFC 6455 frames (DESIGN v2.15 A).
//!
//! As in `transcript`, these functions take and return bytes, strings and
//! records; the types are the uniffi faces of their `powerup-core` twins
//! with a `Core` prefix, converted with exhaustive matches. The listener's
//! machine, which runs all of these rules itself, is in `listener`: the app
//! hands it `CoreServerMessage`s and asks the name table directly, and
//! calls the rest only from its fixture runner.

use powerup_core::protocol::framing::{self, DecodedFrames, Frame, Opcode};
use powerup_core::protocol::handshake::{
    header_boundary, upgrade_decision, RequestHead, UpgradeDecision,
};
use powerup_core::protocol::message::{
    self, parse_client_message, ClientMessage, ClientMessageFailure, ServerMessage, SessionMessage,
};

use crate::mapping::CoreIntent;
use crate::session::CoreAppStatus;
use crate::transcript::CoreTranscriptEntry;
use crate::{contain, CoreBridgeError};

/// A message a client sent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreClientMessage {
    Hello { token: String },
    Intent { intent: CoreIntent },
    Ping,
}

/// Why a client's message was refused: the error code as the wire spells
/// it (HK-229) and the error message's text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreClientMessageFailure {
    pub code: String,
    pub message: String,
}

/// How one client text frame's payload reads.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreClientMessageRead {
    Message { message: CoreClientMessage },
    Failure { failure: CoreClientMessageFailure },
}

impl From<ClientMessage> for CoreClientMessage {
    fn from(message: ClientMessage) -> Self {
        match message {
            ClientMessage::Hello { token } => CoreClientMessage::Hello { token },
            ClientMessage::Intent(intent) => CoreClientMessage::Intent {
                intent: intent.into(),
            },
            ClientMessage::Ping => CoreClientMessage::Ping,
        }
    }
}

impl From<ClientMessageFailure> for CoreClientMessageFailure {
    fn from(failure: ClientMessageFailure) -> Self {
        CoreClientMessageFailure {
            code: failure.code().name().to_owned(),
            message: failure.message(),
        }
    }
}

/// One client text frame's payload read (`message::parse_client_message`,
/// HK-223 to HK-225).
#[uniffi::export]
pub fn protocol_client_message(payload: Vec<u8>) -> Result<CoreClientMessageRead, CoreBridgeError> {
    contain(|| {
        Ok(match parse_client_message(&payload) {
            Ok(message) => CoreClientMessageRead::Message {
                message: message.into(),
            },
            Err(failure) => CoreClientMessageRead::Failure {
                failure: failure.into(),
            },
        })
    })
}

/// The intent a protocol client may send by this wire name, or none when
/// the name is refused (`message::intent_for_protocol_name`, HK-226 to
/// HK-228).
#[uniffi::export]
pub fn protocol_intent(
    name: String,
    text: Option<String>,
) -> Result<Option<CoreIntent>, CoreBridgeError> {
    contain(|| Ok(message::intent_for_protocol_name(&name, text.as_deref()).map(Into::into)))
}

/// The session facts a `session` message carries (HK-232).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSessionMessage {
    pub model: String,
    pub live_model: Option<String>,
    pub effort: String,
    pub permission_mode: String,
    pub control_mode: String,
    pub session_id: Option<String>,
    pub cost_usd: f64,
    pub tokens: i64,
}

/// A message the server sends, case for case with
/// `powerup_core::protocol::message::ServerMessage`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreServerMessage {
    Welcome { app_version: String },
    Status { status: CoreAppStatus },
    Transcript { entry: CoreTranscriptEntry },
    Session { session: CoreSessionMessage },
    Pong,
    Error { code: String, message: String },
}

impl From<CoreSessionMessage> for SessionMessage {
    fn from(session: CoreSessionMessage) -> Self {
        SessionMessage {
            model: session.model,
            live_model: session.live_model,
            effort: session.effort,
            permission_mode: session.permission_mode,
            control_mode: session.control_mode,
            session_id: session.session_id,
            cost_usd: session.cost_usd,
            tokens: session.tokens,
        }
    }
}

impl From<CoreServerMessage> for ServerMessage {
    fn from(message: CoreServerMessage) -> Self {
        match message {
            CoreServerMessage::Welcome { app_version } => ServerMessage::Welcome { app_version },
            CoreServerMessage::Status { status } => ServerMessage::Status(status.into()),
            CoreServerMessage::Transcript { entry } => ServerMessage::Transcript(entry.into()),
            CoreServerMessage::Session { session } => ServerMessage::Session(session.into()),
            CoreServerMessage::Pong => ServerMessage::Pong,
            CoreServerMessage::Error { code, message } => ServerMessage::Error { code, message },
        }
    }
}

/// The text of a server message's frame, or none when it holds a number
/// JSON cannot spell, which is never sent (`message::encode`, HK-230 to
/// HK-234).
#[uniffi::export]
pub fn protocol_encode(message: CoreServerMessage) -> Result<Option<String>, CoreBridgeError> {
    contain(|| Ok(message::encode(&message.into())))
}

/// What a request's bytes on the listener port come to before any body:
/// the head is incomplete, unreadable, not for the WebSocket endpoint, or
/// a refused or accepted upgrade. The method is uppercased and the path
/// has lost its query.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreHandshake {
    Incomplete,
    Unparseable,
    NotWebSocket {
        method: String,
        path: String,
    },
    Refuse {
        method: String,
        path: String,
        status: u16,
        reason: String,
    },
    Accept {
        method: String,
        path: String,
        accept_key: String,
    },
}

/// The handshake for a request's raw bytes (`handshake::header_boundary`,
/// `RequestHead::parse`, then `handshake::upgrade_decision`; HK-218 to
/// HK-222, HK-254).
#[uniffi::export]
pub fn protocol_handshake(request: Vec<u8>) -> Result<CoreHandshake, CoreBridgeError> {
    contain(|| {
        let Some(boundary) = header_boundary(&request) else {
            return Ok(CoreHandshake::Incomplete);
        };
        let Some(head) = request
            .get(..boundary.header_end)
            .and_then(RequestHead::parse)
        else {
            return Ok(CoreHandshake::Unparseable);
        };
        let decision = upgrade_decision(&head);
        let RequestHead { method, path, .. } = head;
        Ok(match decision {
            None => CoreHandshake::NotWebSocket { method, path },
            Some(UpgradeDecision::Reject { status, reason }) => CoreHandshake::Refuse {
                method,
                path,
                status,
                reason: reason.to_owned(),
            },
            Some(UpgradeDecision::Accept { accept_key }) => CoreHandshake::Accept {
                method,
                path,
                accept_key,
            },
        })
    })
}

/// `Sec-WebSocket-Accept` for a client's key (`handshake::accept_key`,
/// HK-235).
#[uniffi::export]
pub fn protocol_accept_key(client_key: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(powerup_core::protocol::handshake::accept_key(&client_key)))
}

/// A frame's opcode, case for case with
/// `powerup_core::protocol::framing::Opcode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreFrameOpcode {
    Continuation,
    Text,
    Binary,
    Close,
    Ping,
    Pong,
}

impl From<Opcode> for CoreFrameOpcode {
    fn from(opcode: Opcode) -> Self {
        match opcode {
            Opcode::Continuation => CoreFrameOpcode::Continuation,
            Opcode::Text => CoreFrameOpcode::Text,
            Opcode::Binary => CoreFrameOpcode::Binary,
            Opcode::Close => CoreFrameOpcode::Close,
            Opcode::Ping => CoreFrameOpcode::Ping,
            Opcode::Pong => CoreFrameOpcode::Pong,
        }
    }
}

impl From<CoreFrameOpcode> for Opcode {
    fn from(opcode: CoreFrameOpcode) -> Self {
        match opcode {
            CoreFrameOpcode::Continuation => Opcode::Continuation,
            CoreFrameOpcode::Text => Opcode::Text,
            CoreFrameOpcode::Binary => Opcode::Binary,
            CoreFrameOpcode::Close => Opcode::Close,
            CoreFrameOpcode::Ping => Opcode::Ping,
            CoreFrameOpcode::Pong => Opcode::Pong,
        }
    }
}

/// One decoded frame, its payload unmasked.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreFrame {
    pub opcode: CoreFrameOpcode,
    pub payload: Vec<u8>,
}

impl From<Frame> for CoreFrame {
    fn from(frame: Frame) -> Self {
        CoreFrame {
            opcode: frame.opcode.into(),
            payload: frame.payload,
        }
    }
}

/// What decoding a buffer came to: the complete frames at its head and how
/// many bytes they took (the rest waits for more), or a protocol violation
/// that refuses the whole buffer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreFrameDecode {
    Frames {
        frames: Vec<CoreFrame>,
        consumed: u64,
    },
    Violation,
}

impl From<DecodedFrames> for CoreFrameDecode {
    fn from(decoded: DecodedFrames) -> Self {
        CoreFrameDecode::Frames {
            frames: decoded.frames.into_iter().map(Into::into).collect(),
            consumed: u64::try_from(decoded.consumed).unwrap_or(u64::MAX),
        }
    }
}

/// Every complete client frame at the head of `buffer`, with payloads of
/// at most `max_payload` bytes (`framing::decode_frames`, HK-236 to
/// HK-242).
#[uniffi::export]
pub fn protocol_decode_frames(
    buffer: Vec<u8>,
    max_payload: u64,
) -> Result<CoreFrameDecode, CoreBridgeError> {
    contain(|| {
        let max_payload = usize::try_from(max_payload).unwrap_or(usize::MAX);
        Ok(match framing::decode_frames(&buffer, max_payload) {
            Ok(decoded) => decoded.into(),
            Err(_) => CoreFrameDecode::Violation,
        })
    })
}

/// One server frame: final, unmasked (`framing::encode_frame`, HK-243).
#[uniffi::export]
pub fn protocol_encode_frame(
    opcode: CoreFrameOpcode,
    payload: Vec<u8>,
) -> Result<Vec<u8>, CoreBridgeError> {
    contain(|| Ok(framing::encode_frame(opcode.into(), &payload)))
}

/// One server text frame (`framing::encode_text`).
#[uniffi::export]
pub fn protocol_encode_text(payload: Vec<u8>) -> Result<Vec<u8>, CoreBridgeError> {
    contain(|| Ok(framing::encode_text(&payload)))
}

/// A close frame carrying `code`, big-endian, with no reason
/// (`framing::encode_close`, HK-244).
#[uniffi::export]
pub fn protocol_encode_close(code: u16) -> Result<Vec<u8>, CoreBridgeError> {
    contain(|| Ok(framing::encode_close(code)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::CoreTranscriptKind;

    #[test]
    fn client_messages_read_like_the_core() {
        assert_eq!(
            protocol_client_message(br#"{"type":"hello","token":"t"}"#.to_vec()),
            Ok(CoreClientMessageRead::Message {
                message: CoreClientMessage::Hello {
                    token: "t".to_owned()
                }
            })
        );
        assert_eq!(
            protocol_client_message(
                br#"{"type":"intent","intent":"sendPrompt","text":" hi "}"#.to_vec()
            ),
            Ok(CoreClientMessageRead::Message {
                message: CoreClientMessage::Intent {
                    intent: CoreIntent::SendPrompt {
                        prompt: "hi".to_owned()
                    }
                }
            })
        );
        assert_eq!(
            protocol_client_message(br#"{"type":"intent","intent":"pushToTalk"}"#.to_vec()),
            Ok(CoreClientMessageRead::Failure {
                failure: CoreClientMessageFailure {
                    code: "unknown_intent".to_owned(),
                    message: "Unknown or disallowed intent \"pushToTalk\" (see docs/protocol.md for the allowed set).".to_owned(),
                }
            })
        );
        assert_eq!(
            protocol_client_message(vec![0xFF]),
            Ok(CoreClientMessageRead::Failure {
                failure: CoreClientMessageFailure {
                    code: "malformed".to_owned(),
                    message: "Messages must be single JSON objects with a \"type\" field."
                        .to_owned(),
                }
            })
        );
        assert_eq!(
            protocol_intent("toggleTTS".to_owned(), None),
            Ok(Some(CoreIntent::ToggleTts))
        );
        assert_eq!(
            protocol_intent("bypassPermissions".to_owned(), None),
            Ok(None)
        );
    }

    #[test]
    fn every_server_message_crosses_and_encodes() {
        let cases = [
            (
                CoreServerMessage::Welcome {
                    app_version: "1.2".to_owned(),
                },
                Some(r#"{"type":"welcome","protocol":0,"app":"PowerUp","version":"1.2"}"#),
            ),
            (
                CoreServerMessage::Status {
                    status: CoreAppStatus::NoController,
                },
                Some(r#"{"type":"status","status":"noController"}"#),
            ),
            (
                CoreServerMessage::Transcript {
                    entry: CoreTranscriptEntry {
                        id: "3f2504e0-4f89-41d3-9a0c-0305e82c3301".to_owned(),
                        kind: CoreTranscriptKind::Tool,
                        text: "a/b".to_owned(),
                        date_seconds: 1.5,
                    },
                },
                Some(
                    r#"{"type":"transcript","entry":{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","kind":"tool","text":"a\/b","date":1.5}}"#,
                ),
            ),
            (
                CoreServerMessage::Session {
                    session: CoreSessionMessage {
                        model: "default".to_owned(),
                        live_model: Some(String::new()),
                        effort: "high".to_owned(),
                        permission_mode: "plan".to_owned(),
                        control_mode: "local".to_owned(),
                        session_id: Some("s1".to_owned()),
                        cost_usd: 0.25,
                        tokens: 12,
                    },
                },
                Some(
                    r#"{"type":"session","model":"default","effort":"high","permissionMode":"plan","controlMode":"local","costUSD":0.25,"tokens":12,"sessionID":"s1"}"#,
                ),
            ),
            (CoreServerMessage::Pong, Some(r#"{"type":"pong"}"#)),
            (
                CoreServerMessage::Error {
                    code: "server_busy".to_owned(),
                    message: "busy".to_owned(),
                },
                Some(r#"{"type":"error","code":"server_busy","message":"busy"}"#),
            ),
            (
                CoreServerMessage::Session {
                    session: CoreSessionMessage {
                        model: "m".to_owned(),
                        live_model: None,
                        effort: "e".to_owned(),
                        permission_mode: "p".to_owned(),
                        control_mode: "c".to_owned(),
                        session_id: None,
                        cost_usd: f64::NAN,
                        tokens: 0,
                    },
                },
                None,
            ),
        ];
        for (message, text) in cases {
            assert_eq!(protocol_encode(message), Ok(text.map(str::to_owned)));
        }
    }

    #[test]
    fn the_handshake_comes_to_each_outcome() {
        let request = |text: &str| text.as_bytes().to_vec();
        assert_eq!(
            protocol_handshake(request("GET /ws HTTP/1.1\r\n")),
            Ok(CoreHandshake::Incomplete)
        );
        assert_eq!(
            protocol_handshake(request("GET\r\n\r\n")),
            Ok(CoreHandshake::Unparseable)
        );
        assert_eq!(
            protocol_handshake(request("post /event?x=1 HTTP/1.1\n\n")),
            Ok(CoreHandshake::NotWebSocket {
                method: "POST".to_owned(),
                path: "/event".to_owned(),
            })
        );
        let upgrade = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                       Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
        assert_eq!(
            protocol_handshake(request(&format!("{upgrade}Origin: https://x\r\n\r\n"))),
            Ok(CoreHandshake::Refuse {
                method: "GET".to_owned(),
                path: "/ws".to_owned(),
                status: 403,
                reason: "Forbidden".to_owned(),
            })
        );
        assert_eq!(
            protocol_handshake(request(&format!("{upgrade}\r\n"))),
            Ok(CoreHandshake::Accept {
                method: "GET".to_owned(),
                path: "/ws".to_owned(),
                accept_key: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".to_owned(),
            })
        );
        assert_eq!(
            protocol_accept_key("dGhlIHNhbXBsZSBub25jZQ==".to_owned()),
            Ok("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".to_owned())
        );
    }

    #[test]
    fn frames_decode_and_encode_through_the_bridge() {
        // A masked "Hi" text frame, then the first byte of the next frame.
        let buffer = vec![0x81, 0x82, 1, 2, 3, 4, b'H' ^ 1, b'i' ^ 2, 0x89];
        assert_eq!(
            protocol_decode_frames(buffer, 1024),
            Ok(CoreFrameDecode::Frames {
                frames: vec![CoreFrame {
                    opcode: CoreFrameOpcode::Text,
                    payload: b"Hi".to_vec(),
                }],
                consumed: 8,
            })
        );
        // Unmasked: a violation.
        assert_eq!(
            protocol_decode_frames(vec![0x81, 0x00], 1024),
            Ok(CoreFrameDecode::Violation)
        );
        assert_eq!(
            protocol_encode_frame(CoreFrameOpcode::Pong, b"p".to_vec()),
            Ok(vec![0x8A, 0x01, b'p'])
        );
        assert_eq!(
            protocol_encode_text(b"ok".to_vec()),
            Ok(vec![0x81, 0x02, b'o', b'k'])
        );
        assert_eq!(
            protocol_encode_close(1002),
            Ok(vec![0x88, 0x02, 0x03, 0xEA])
        );
        for opcode in [
            CoreFrameOpcode::Continuation,
            CoreFrameOpcode::Text,
            CoreFrameOpcode::Binary,
            CoreFrameOpcode::Close,
            CoreFrameOpcode::Ping,
            CoreFrameOpcode::Pong,
        ] {
            assert_eq!(CoreFrameOpcode::from(Opcode::from(opcode)), opcode);
        }
    }
}
