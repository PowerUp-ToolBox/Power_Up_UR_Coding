//! Plays `Tests/Fixtures/listener/` (spec #101, slice 2.6, #162) against
//! the core's connection policy: each scenario drives one
//! `protocol::listener::Listener` input by input and compares the effects
//! of every step, in order, with the ones the scenario lists. No socket is
//! opened and no timer runs; a fired timer is an input like any other.
//!
//! A sent buffer is compared by what it is: HTTP response text, one
//! protocol message (its JSON, members in any order; the member order is
//! `protocol/server-message.json`'s to pin), a close code, a pong payload,
//! or raw bytes.

mod support;

use powerup_core::intent::Intent;
use powerup_core::protocol::listener::{
    hook_post, BindError, HookPost, Listener, ListenerEffect, ListenerStatus, MAX_AUTHENTICATED,
    MAX_CONNECTIONS,
};
use powerup_core::session::HookKind;
use serde_json::{json, Value};
use support::{
    descriptor_bytes, hex_descriptor, intent_descriptor, json_files, load_listener_scenario,
    number_value, server_message_from, ListenerStep,
};

fn connection(value: &Value) -> u64 {
    value
        .as_u64()
        .unwrap_or_else(|| panic!("not a connection id: {value}"))
}

fn generation(value: &Value) -> u64 {
    value
        .as_u64()
        .unwrap_or_else(|| panic!("not a generation: {value}"))
}

fn port(value: &Value) -> u16 {
    value["port"]
        .as_u64()
        .and_then(|port| u16::try_from(port).ok())
        .unwrap_or_else(|| panic!("not a port: {value}"))
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("no string {key} in {value}"))
}

/// `"addressInUse"` or `{"other": <detail>}`.
fn bind_error(value: &Value) -> BindError {
    match value {
        Value::String(name) if name == "addressInUse" => BindError::AddressInUse,
        Value::Object(_) => BindError::Other(text(value, "other").to_owned()),
        other => panic!("not a bind error: {other}"),
    }
}

/// Runs one step's input.
fn run(listener: &mut Listener, step: &ListenerStep) -> Vec<ListenerEffect> {
    let value = &step.value;
    match step.input.as_str() {
        "start" => listener.start(port(value), text(value, "token")),
        "stop" => listener.stop(),
        "bindReady" => listener.bind_ready(generation(value)),
        "bindWaiting" => listener.bind_waiting(
            generation(&value["generation"]),
            &bind_error(&value["error"]),
        ),
        "bindFailed" => listener.bind_failed(
            generation(&value["generation"]),
            &bind_error(&value["error"]),
        ),
        "bindCancelled" => listener.bind_cancelled(generation(value)),
        "listenRefused" => {
            listener.listen_refused(generation(&value["generation"]), text(value, "detail"))
        }
        "retryFired" => listener.retry_fired(generation(value)),
        "accept" => listener.accepted(generation(value)),
        "receive" => listener.received(
            connection(&value["connection"]),
            &descriptor_bytes(&value["bytes"]),
        ),
        "endOfStream" => listener.end_of_stream(connection(value)),
        "closed" => listener.closed(connection(value)),
        "deadlineFired" => listener.deadline_fired(connection(value)),
        "broadcast" => listener.broadcast(&server_message_from(value)),
        "welcome" => {
            let snapshot: Vec<_> = value["snapshot"]
                .as_array()
                .unwrap_or_else(|| panic!("a welcome needs a snapshot list: {value}"))
                .iter()
                .map(server_message_from)
                .collect();
            listener.welcome(
                connection(&value["connection"]),
                text(value, "appVersion"),
                &snapshot,
            )
        }
        other => panic!("unknown input {other}"),
    }
}

/// One unmasked, final server frame: its opcode and payload, or `None`
/// when the bytes are anything else.
fn server_frame(bytes: &[u8]) -> Option<(u8, &[u8])> {
    let (&first, rest) = bytes.split_first()?;
    let (&second, rest) = rest.split_first()?;
    if first & 0xF0 != 0x80 || second & 0x80 != 0 {
        return None;
    }
    let (length, payload) = match second {
        126 => {
            let (length, payload) = rest.split_at_checked(2)?;
            (
                usize::from(u16::from_be_bytes(length.try_into().ok()?)),
                payload,
            )
        }
        127 => {
            let (length, payload) = rest.split_at_checked(8)?;
            (
                usize::try_from(u64::from_be_bytes(length.try_into().ok()?)).ok()?,
                payload,
            )
        }
        short => (usize::from(short), rest),
    };
    (payload.len() == length).then_some((first & 0x0F, payload))
}

/// What a sent buffer is, as a scenario writes it.
fn sent(bytes: &[u8]) -> (&'static str, Value) {
    if bytes.starts_with(b"HTTP/") {
        if let Ok(response) = std::str::from_utf8(bytes) {
            return ("http", json!(response));
        }
    }
    match server_frame(bytes) {
        Some((0x1, payload)) => match std::str::from_utf8(payload) {
            Ok(message) => match serde_json::from_str::<Value>(message) {
                Ok(object @ Value::Object(_)) => ("message", object),
                _ => ("text", json!(message)),
            },
            Err(_) => ("hex", hex_descriptor(bytes)),
        },
        Some((0x8, &[high, low])) => ("close", json!(u16::from_be_bytes([high, low]))),
        Some((0xA, payload)) => ("pong", hex_descriptor(payload)),
        _ => ("hex", hex_descriptor(bytes)),
    }
}

fn hook_kind_name(kind: HookKind) -> &'static str {
    match kind {
        HookKind::Stop => "stop",
        HookKind::UserPromptSubmit => "userPromptSubmit",
        HookKind::Notification => "notification",
        HookKind::SessionEnd => "sessionEnd",
        HookKind::PostToolUse => "postToolUse",
    }
}

fn hook_descriptor(hook: &HookPost) -> Value {
    json!({
        "kind": hook_kind_name(hook.kind),
        "text": hook.text,
        "sessionID": hook.session_id,
        "cwd": hook.cwd,
    })
}

fn status_descriptor(status: &ListenerStatus) -> Value {
    json!({
        "effect": "publish",
        "running": status.running,
        "problem": status.problem.as_ref().map(|problem| problem.message()),
    })
}

/// An effect as a scenario writes it.
fn effect_descriptor(effect: &ListenerEffect) -> Value {
    match effect {
        ListenerEffect::Publish(status) => status_descriptor(status),
        ListenerEffect::Listen { generation, port } => {
            json!({"effect": "listen", "generation": generation, "port": port})
        }
        ListenerEffect::StopListening => json!({"effect": "stopListening"}),
        ListenerEffect::ScheduleBindRetry {
            generation,
            seconds,
        } => json!({
            "effect": "scheduleBindRetry", "generation": generation,
            "seconds": number_value(*seconds),
        }),
        ListenerEffect::Admit { connection } => {
            json!({"effect": "admit", "connection": connection})
        }
        ListenerEffect::Refuse => json!({"effect": "refuse"}),
        ListenerEffect::ArmIdleDeadline {
            connection,
            seconds,
        } => json!({
            "effect": "armIdleDeadline", "connection": connection,
            "seconds": number_value(*seconds),
        }),
        ListenerEffect::Send { connection, bytes } => {
            let (key, value) = sent(bytes);
            json!({"effect": "send", "connection": connection, key: value})
        }
        ListenerEffect::Broadcast { connections, bytes } => {
            let (key, value) = sent(bytes);
            json!({"effect": "broadcast", "connections": connections, key: value})
        }
        ListenerEffect::Close { connection } => {
            json!({"effect": "close", "connection": connection})
        }
        ListenerEffect::Cancel { connection } => {
            json!({"effect": "cancel", "connection": connection})
        }
        ListenerEffect::DeliverHook { generation, hook } => json!({
            "effect": "deliverHook", "generation": generation, "hook": hook_descriptor(hook),
        }),
        ListenerEffect::DeliverIntent { generation, intent } => json!({
            "effect": "deliverIntent", "generation": generation,
            "intent": intent_descriptor(intent),
        }),
        ListenerEffect::Welcome { connection } => {
            json!({"effect": "welcome", "connection": connection})
        }
    }
}

/// A scenario's effect with its bytes descriptors reduced to hex, the
/// spelling `effect_descriptor` writes.
fn expected_effect(effect: &Value) -> Value {
    let mut effect = effect.clone();
    if let Some(pong) = effect.get_mut("pong") {
        *pong = hex_descriptor(&descriptor_bytes(pong));
    }
    if let Some(hex) = effect.get_mut("hex") {
        *hex = hex_descriptor(&descriptor_bytes(hex));
    }
    effect
}

fn state(listener: &Listener) -> Value {
    json!({
        "connections": listener.connection_count(),
        "authenticated": listener.authenticated_count(),
        "generation": listener.generation(),
        "running": listener.status().running,
    })
}

#[test]
fn listener_scenarios() {
    let files = json_files("listener");
    assert!(!files.is_empty(), "no listener scenarios");
    for path in files {
        let (scenario, steps) = load_listener_scenario(&path);
        let mut listener = Listener::new();
        for (index, step) in steps.iter().enumerate() {
            let actual: Vec<Value> = run(&mut listener, step)
                .iter()
                .map(effect_descriptor)
                .collect();
            let expected: Vec<Value> = step.effects.iter().map(expected_effect).collect();
            let context = || {
                format!(
                    "{} step {index} ({} {}) failed (guards: {})",
                    scenario.name, step.input, step.value, step.reason
                )
            };
            if actual != expected {
                panic!(
                    "{}\n  expected:\n{}\n  actual:\n{}",
                    context(),
                    pretty(&expected),
                    pretty(&actual)
                );
            }
            if let Some(facts) = &step.state {
                let now = state(&listener);
                for (key, want) in facts {
                    assert_eq!(&now[key.as_str()], want, "{}: state {key}", context());
                }
            }
        }
    }
}

fn pretty(effects: &[Value]) -> String {
    effects
        .iter()
        .map(|effect| format!("    {effect}"))
        .collect::<Vec<_>>()
        .join("\n")
}

// Pins beyond the scenarios.

#[test]
fn the_spec_constants_are_the_documented_ones() {
    use powerup_core::protocol::listener::*;
    assert_eq!(MAX_CONNECTIONS, 32);
    assert_eq!(MAX_AUTHENTICATED, 16);
    assert_eq!(IDLE_DEADLINE_SECONDS, 15.0);
    assert_eq!(MAX_HEADER_BYTES, 16 * 1024);
    assert_eq!(MAX_BODY_BYTES, 4 * 1024 * 1024);
    assert_eq!(MAX_PAYLOAD_BYTES, 1024 * 1024);
    assert_eq!(MAX_WEBSOCKET_BUFFER_BYTES, 2 * 1024 * 1024);
    assert_eq!(RECEIVE_CHUNK_BYTES, 32 * 1024);
    assert_eq!(MAX_BIND_RETRIES, 3);
    assert_eq!(BIND_RETRY_STEP_SECONDS, 2.0);
    assert_eq!(MIN_PORT, 1024);
}

/// The hook-burst rule however the cap fills: whatever mix of
/// authenticated clients and other connections, an accept past the cap
/// never cancels an authenticated client or the new connection.
#[test]
fn no_accept_ever_cancels_an_authenticated_client() {
    for plugins in 0..=MAX_AUTHENTICATED {
        let mut listener = Listener::new();
        listener.start(48738, "secret");
        listener.bind_ready(2);
        let mut authenticated = Vec::new();
        for _ in 0..plugins {
            let id = admitted(&listener.accepted(2));
            let mut request = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
                .to_vec();
            let hello = br#"{"type":"hello","token":"secret"}"#;
            request.extend_from_slice(&[0x81, 0x80 | hello.len() as u8, 0, 0, 0, 0]);
            request.extend_from_slice(hello);
            let effects = listener.received(id, &request);
            assert!(effects.contains(&ListenerEffect::Welcome { connection: id }));
            authenticated.push(id);
        }
        for _ in 0..3 * MAX_CONNECTIONS {
            let effects = listener.accepted(2);
            let new = admitted(&effects);
            for effect in &effects {
                if let ListenerEffect::Cancel { connection } = effect {
                    assert!(
                        !authenticated.contains(connection),
                        "a plugin was cancelled"
                    );
                    assert_ne!(*connection, new, "the new connection was cancelled");
                }
            }
            assert!(listener.connection_count() <= MAX_CONNECTIONS);
            assert_eq!(listener.authenticated_count(), plugins);
        }
    }
}

fn admitted(effects: &[ListenerEffect]) -> u64 {
    effects
        .iter()
        .find_map(|effect| match effect {
            ListenerEffect::Admit { connection } => Some(*connection),
            _ => None,
        })
        .unwrap_or_else(|| panic!("nothing admitted: {effects:?}"))
}

/// Random bytes on every input never panic, and the machine keeps its
/// bounds: no more than the cap of connections, no more authenticated ones
/// than their cap.
#[test]
fn random_input_never_panics() {
    let mut seed: u64 = 0x5DEE_CE66_D1CE_4E5B;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let pieces: [&[u8]; 8] = [
        b"POST /event HTTP/1.1\r\nX-PowerUp-Token: secret\r\nContent-Length: 2\r\n\r\n{}",
        b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
          Sec-WebSocket-Key: a\r\nSec-WebSocket-Version: 13\r\n\r\n",
        b"\x81\x9f\0\0\0\0{\"type\":\"hello\",\"token\":\"secret\"}",
        b"\x81\x8f\0\0\0\0{\"type\":\"ping\"}",
        b"\x88\x82\0\0\0\0\x03\xe8",
        b"\n\n\r\n",
        b"\xff\xfe\x00",
        b"Expect: 100-continue\r\nTransfer-Encoding: chunked\r\n",
    ];
    let mut listener = Listener::new();
    for _ in 0..20_000 {
        let roll = next();
        let id = 1 + (next() % 48);
        match roll % 12 {
            0 => drop(listener.start(48738, "secret")),
            1 => drop(listener.bind_ready(listener.generation())),
            2 => drop(listener.bind_failed(listener.generation(), &BindError::AddressInUse)),
            3 => drop(listener.retry_fired(listener.generation())),
            4 | 5 => drop(listener.accepted(listener.generation())),
            6 | 7 => {
                let piece = pieces[(next() % pieces.len() as u64) as usize];
                let cut = (next() as usize) % (piece.len() + 1);
                drop(listener.received(id, &piece[..cut]));
                drop(listener.received(id, &piece[cut..]));
            }
            8 => {
                let noise: Vec<u8> = (0..next() % 64).map(|_| next() as u8).collect();
                drop(listener.received(id, &noise));
            }
            9 => drop(listener.end_of_stream(id)),
            10 => drop(listener.deadline_fired(id)),
            _ => drop(listener.closed(id)),
        }
        assert!(listener.connection_count() <= MAX_CONNECTIONS);
        assert!(listener.authenticated_count() <= MAX_AUTHENTICATED);
    }
}

#[test]
fn a_hook_post_is_read_as_a_client_message_is() {
    // A UTF-16 body is read, as JSONSerialization reads one.
    let utf16: Vec<u8> = r#"{"hook_event_name":"Stop","cwd":"/a"}"#
        .encode_utf16()
        .flat_map(u16::to_be_bytes)
        .collect();
    assert_eq!(
        hook_post(&utf16),
        Some(HookPost {
            kind: HookKind::Stop,
            text: None,
            session_id: None,
            cwd: Some("/a".to_owned()),
        })
    );
    assert_eq!(hook_post(b""), None);
    assert_eq!(hook_post(b"\"Stop\""), None);
}

#[test]
fn every_intent_the_wire_allows_reaches_the_app_with_its_generation() {
    let mut listener = Listener::new();
    listener.start(48738, "secret");
    let id = admitted(&listener.accepted(2));
    let mut bytes = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
        Sec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\n\r\n"
        .to_vec();
    for message in [
        r#"{"type":"hello","token":"secret"}"#,
        r#"{"type":"intent","intent":"cycleModel"}"#,
    ] {
        bytes.extend_from_slice(&[0x81, 0x80 | message.len() as u8, 0, 0, 0, 0]);
        bytes.extend_from_slice(message.as_bytes());
    }
    let effects = listener.received(id, &bytes);
    assert_eq!(
        effects.last(),
        Some(&ListenerEffect::DeliverIntent {
            generation: 2,
            intent: Intent::CycleModel,
        })
    );
}
