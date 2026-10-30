//! Plays `Tests/Fixtures/protocol/` (spec #101, slice 2.6) against the
//! core: the same tables `ProtocolFixtureTests` plays through the bridge
//! (`CoreBridgeProtocol.swift`). Only fixture bytes are read; no socket is
//! opened.
//!
//! The core fixes the member order `server-message.json` shows, and both
//! runners compare a server message's text byte for byte.

mod support;

use std::collections::BTreeSet;

use powerup_core::intent::Intent;
use powerup_core::protocol::framing::{
    close_code, decode_frames, encode_close, encode_frame, encode_text, Opcode,
};
use powerup_core::protocol::handshake::{
    accept_key, header_boundary, upgrade_decision, RequestHead, UpgradeDecision,
};
use powerup_core::protocol::message::{
    encode, intent_for_protocol_name, parse_client_message, ClientMessage,
};
use serde_json::{json, Value};
use support::{
    case_table, descriptor_bytes, hex_descriptor, intent_descriptor, server_message_from, CaseTable,
};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

/// Plays every case of `file`: `actual` maps an input to the value the
/// table expects, and `expected` normalises the table's expectation (bytes
/// descriptors compare by the bytes they stand for).
fn play(
    file: &str,
    actual: impl Fn(&Value) -> Value,
    expected: impl Fn(&Value) -> Value,
) -> CaseTable {
    let table = case_table("protocol", file);
    for case in &table.cases {
        let want = expected(&case.expected);
        let got = actual(&case.input);
        assert_eq!(
            got,
            want,
            "{}",
            fail(file, &case.name, &case.reason, &want, &got)
        );
    }
    table
}

fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("no string {key} in {value}"))
}

fn client_message(payload: &[u8]) -> Value {
    match parse_client_message(payload) {
        Ok(ClientMessage::Hello { token }) => json!({"type": "hello", "token": token}),
        Ok(ClientMessage::Intent(intent)) => {
            let mut descriptor = intent_descriptor(&intent);
            descriptor["type"] = json!("intent");
            descriptor
        }
        Ok(ClientMessage::Ping) => json!({"type": "ping"}),
        Err(failure) => json!({"error": failure.code().name(), "message": failure.message()}),
    }
}

fn handshake(request: &[u8]) -> Value {
    let Some(boundary) = header_boundary(request) else {
        return json!({"outcome": "incomplete"});
    };
    let Some(head) = RequestHead::parse(&request[..boundary.header_end]) else {
        return json!({"outcome": "unparseable"});
    };
    let mut fields = json!({"method": head.method, "path": head.path});
    match upgrade_decision(&head) {
        None => fields["outcome"] = json!("notWebSocket"),
        Some(UpgradeDecision::Reject { status, reason }) => {
            fields["outcome"] = json!("refuse");
            fields["status"] = json!(status);
            fields["reason"] = json!(reason);
        }
        Some(UpgradeDecision::Accept { accept_key }) => {
            fields["outcome"] = json!("accept");
            fields["acceptKey"] = json!(accept_key);
        }
    }
    fields
}

fn opcode(name: &str) -> Opcode {
    (0..=0x0F)
        .filter_map(Opcode::from_bits)
        .find(|opcode| opcode.name() == name)
        .unwrap_or_else(|| panic!("unknown opcode {name}"))
}

fn frame_decode(input: &Value) -> Value {
    let buffer = descriptor_bytes(&input["buffer"]);
    let max_payload = input["maxPayload"]
        .as_u64()
        .and_then(|n| usize::try_from(n).ok())
        .unwrap_or_else(|| panic!("maxPayload must be a count: {input}"));
    match decode_frames(&buffer, max_payload) {
        Err(_) => json!({"error": "protocolViolation"}),
        Ok(decoded) => json!({
            "frames": decoded.frames.iter().map(|frame| json!({
                "opcode": frame.opcode.name(),
                "payload": hex_descriptor(&frame.payload),
            })).collect::<Vec<_>>(),
            "remaining": hex_descriptor(&buffer[decoded.consumed..]),
        }),
    }
}

/// A decode expectation with every bytes descriptor spelled as `{"hex"}`.
fn decoded_bytes(expected: &Value) -> Value {
    let Some(frames) = expected["frames"].as_array() else {
        return expected.clone();
    };
    json!({
        "frames": frames.iter().map(|frame| json!({
            "opcode": frame["opcode"],
            "payload": hex_descriptor(&descriptor_bytes(&frame["payload"])),
        })).collect::<Vec<_>>(),
        "remaining": hex_descriptor(&descriptor_bytes(&expected["remaining"])),
    })
}

fn frame_encode(input: &Value) -> Value {
    if let Some(code) = input.get("close") {
        let code = code
            .as_u64()
            .and_then(|code| u16::try_from(code).ok())
            .unwrap_or_else(|| panic!("bad close code {code}"));
        return hex_descriptor(&encode_close(code));
    }
    let payload = descriptor_bytes(&input["payload"]);
    let opcode = opcode(string(input, "opcode"));
    let frame = encode_frame(opcode, &payload);
    if opcode == Opcode::Text {
        assert_eq!(encode_text(&payload), frame, "encode_text is a text frame");
    }
    hex_descriptor(&frame)
}

#[test]
fn client_message_cases() {
    let table = play(
        "client-message.json",
        |input| client_message(&descriptor_bytes(input)),
        Clone::clone,
    );
    let expected: Vec<&Value> = table.cases.iter().map(|case| &case.expected).collect();
    for kind in ["hello", "intent", "ping"] {
        assert!(
            expected.iter().any(|e| e["type"] == kind),
            "client-message.json has no {kind} case"
        );
    }
    for code in [
        "malformed",
        "unknown_type",
        "bad_hello",
        "unsupported_protocol",
        "unknown_intent",
    ] {
        assert!(
            expected.iter().any(|e| e["error"] == code),
            "client-message.json has no {code} case"
        );
    }
}

#[test]
fn intent_name_cases() {
    let table = play(
        "intent-names.json",
        |input| {
            let text = match &input["text"] {
                Value::String(text) => Some(text.as_str()),
                Value::Null => None,
                other => panic!("text must be a string or null, not {other}"),
            };
            intent_for_protocol_name(string(input, "name"), text)
                .as_ref()
                .map_or(Value::Null, intent_descriptor)
        },
        Clone::clone,
    );
    let mapped: BTreeSet<&str> = table
        .cases
        .iter()
        .filter_map(|case| case.expected["intent"].as_str())
        .collect();
    assert_eq!(mapped.len(), 16, "every protocol name maps in the table");
    for voice in [
        "beginVoiceCapture",
        "endVoiceCapture",
        "pushToTalk",
        "pushToTalkDraft",
    ] {
        assert!(
            table
                .cases
                .iter()
                .any(|case| case.input["name"] == voice && case.expected.is_null()),
            "intent-names.json must refuse {voice}"
        );
    }
    // No voice capture, whatever text comes with it (HK-226).
    for name in mapped {
        let intent = intent_for_protocol_name(name, Some("text"));
        assert!(!matches!(
            intent,
            Some(Intent::BeginVoiceCapture(_) | Intent::EndVoiceCapture)
        ));
    }
}

#[test]
fn server_message_cases() {
    let table = play(
        "server-message.json",
        |input| encode(&server_message_from(input)).map_or(Value::Null, Value::String),
        Clone::clone,
    );
    for case in &table.cases {
        if let Some(text) = case.expected.as_str() {
            assert!(
                !text.contains('\n'),
                "{}: a message is one line (HK-233)",
                case.name
            );
        }
    }
}

#[test]
fn handshake_cases() {
    let table = play(
        "handshake.json",
        |input| handshake(&descriptor_bytes(input)),
        Clone::clone,
    );
    let outcomes: BTreeSet<&str> = table
        .cases
        .iter()
        .filter_map(|case| case.expected["outcome"].as_str())
        .collect();
    assert_eq!(
        outcomes,
        BTreeSet::from([
            "accept",
            "incomplete",
            "notWebSocket",
            "refuse",
            "unparseable"
        ])
    );
}

#[test]
fn accept_key_cases() {
    play(
        "accept-key.json",
        |input| {
            json!(accept_key(
                input
                    .as_str()
                    .unwrap_or_else(|| panic!("not a key: {input}"))
            ))
        },
        Clone::clone,
    );
}

#[test]
fn frame_decode_cases() {
    play("frame-decode.json", frame_decode, decoded_bytes);
}

#[test]
fn frame_encode_cases() {
    let table = play("frame-encode.json", frame_encode, |expected| {
        hex_descriptor(&descriptor_bytes(expected))
    });
    let codes: BTreeSet<u64> = table
        .cases
        .iter()
        .filter_map(|case| case.input["close"].as_u64())
        .collect();
    for code in [
        close_code::NORMAL,
        close_code::PROTOCOL_ERROR,
        close_code::UNSUPPORTED_DATA,
        close_code::MESSAGE_TOO_BIG,
        close_code::TRY_AGAIN_LATER,
        close_code::AUTH_FAILED,
        close_code::NOT_AUTHENTICATED,
    ] {
        assert!(
            codes.contains(&u64::from(code)),
            "frame-encode.json must encode close {code}"
        );
    }
}
