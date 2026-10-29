//! The protocol v0 messages (DESIGN v1.7; `docs/protocol.md` "Client →
//! server" and "Server → client"): how a client's text frame reads, the
//! intents a client may name, the error codes and their text, and every
//! server message as the exact text of its frame. Ported from the Swift
//! app's `PowerUpProtocol` and `IntentMapper.intent(forProtocolName:text:)`;
//! the tables in `Tests/Fixtures/protocol/` pin each rule, including how
//! Foundation's `JSONSerialization` reads a client's bytes and writes a
//! server's.

use crate::intent::Intent;
use crate::json::{self, JsonNumber, JsonValue};
use crate::status::AppStatus;
use crate::text::trim;
use crate::transcript::TranscriptEntry;
use crate::wire;

/// The protocol version this server speaks. Pre-1.0: it may change
/// incompatibly between app versions, which the hello and welcome
/// exchange makes fail loudly (HK-217).
pub const PROTOCOL_VERSION: i64 = 0;

/// The app name a welcome carries.
pub const APP_NAME: &str = "PowerUp";

/// A message a client sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientMessage {
    /// Authenticate with the listener token.
    Hello { token: String },
    /// Perform one intent.
    Intent(Intent),
    /// Liveness check, answered with a pong.
    Ping,
}

/// The error codes clients branch on (HK-229): the five a message can fail
/// with, and the three the listener refuses a connection with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    Malformed,
    UnknownType,
    BadHello,
    UnsupportedProtocol,
    UnknownIntent,
    AuthFailed,
    NotAuthenticated,
    ServerBusy,
}

impl ErrorCode {
    /// The code as the wire spells it.
    pub fn name(self) -> &'static str {
        match self {
            ErrorCode::Malformed => "malformed",
            ErrorCode::UnknownType => "unknown_type",
            ErrorCode::BadHello => "bad_hello",
            ErrorCode::UnsupportedProtocol => "unsupported_protocol",
            ErrorCode::UnknownIntent => "unknown_intent",
            ErrorCode::AuthFailed => "auth_failed",
            ErrorCode::NotAuthenticated => "not_authenticated",
            ErrorCode::ServerBusy => "server_busy",
        }
    }
}

/// The `auth_failed` message: the hello's token is not the listener's.
pub const AUTH_FAILED_MESSAGE: &str =
    "The token doesn't match \u{2014} copy it from Settings \u{2192} Remote \u{2192} Read-back.";

/// The `not_authenticated` message: an intent came before the hello.
pub const NOT_AUTHENTICATED_MESSAGE: &str = "Send hello with the token before anything else.";

/// The `server_busy` message: the authenticated client cap is reached.
pub const SERVER_BUSY_MESSAGE: &str = "Too many protocol clients are connected.";

/// Why a client's message was refused. The listener answers each with an
/// error message ([`ServerMessage::failure`]); what it then does with the
/// connection (close 1002 for malformed, bad_hello and
/// unsupported_protocol, keep it otherwise, HK-224) is its policy's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientMessageFailure {
    /// Not one JSON object with a string `type`.
    Malformed,
    /// A `type` this server does not know, named as sent.
    UnknownType(String),
    /// A hello without a non-empty string token.
    BadHello,
    /// A hello asking for another version, as read.
    UnsupportedProtocol(i64),
    /// An intent name the table refuses, as sent (`""` when absent).
    UnknownIntent(String),
}

impl ClientMessageFailure {
    pub fn code(&self) -> ErrorCode {
        match self {
            ClientMessageFailure::Malformed => ErrorCode::Malformed,
            ClientMessageFailure::UnknownType(_) => ErrorCode::UnknownType,
            ClientMessageFailure::BadHello => ErrorCode::BadHello,
            ClientMessageFailure::UnsupportedProtocol(_) => ErrorCode::UnsupportedProtocol,
            ClientMessageFailure::UnknownIntent(_) => ErrorCode::UnknownIntent,
        }
    }

    /// The error message's text; a name is quoted raw (the encoder escapes
    /// it).
    pub fn message(&self) -> String {
        match self {
            ClientMessageFailure::Malformed => {
                "Messages must be single JSON objects with a \"type\" field.".to_owned()
            }
            ClientMessageFailure::UnknownType(kind) => format!("Unknown message type \"{kind}\"."),
            ClientMessageFailure::BadHello => "hello must carry a non-empty \"token\".".to_owned(),
            ClientMessageFailure::UnsupportedProtocol(requested) => format!(
                "This server speaks protocol {PROTOCOL_VERSION}; you asked for {requested}."
            ),
            ClientMessageFailure::UnknownIntent(name) => format!(
                "Unknown or disallowed intent \"{name}\" (see docs/protocol.md for the allowed set)."
            ),
        }
    }
}

/// One client text frame's payload as a message.
///
/// The bytes are read as Foundation's `JSONSerialization` reads them
/// (`json::read_any_encoding`: UTF-8 with its measured tolerances, or
/// UTF-16 and UTF-32 it detects), so there is no separate UTF-8 step: text
/// that is not UTF-8 is `malformed` like any other unreadable payload, and
/// the close code stays 1002, never RFC 6455's 1007 (HK-225). The root must
/// be an object whose first `type` member is a string, else `malformed`
/// (HK-224). Unknown fields are ignored; of equal keys the first counts.
///
/// - `hello` needs a `token` that is a non-empty string, kept exactly (not
///   trimmed), else `bad_hello`; then its `protocol` must read as 0, else
///   `unsupported_protocol`, and a missing one is 0 so a minimal client can
///   connect (HK-223). The token is checked first.
/// - `intent` maps its `intent` member (`""` unless a string) and, for
///   sendPrompt, its string `text` through [`intent_for_protocol_name`]; a
///   name the table refuses is `unknown_intent`.
/// - `ping` takes no fields. Any other type, the empty one and the
///   server's own included, is `unknown_type`.
pub fn parse_client_message(payload: &[u8]) -> Result<ClientMessage, ClientMessageFailure> {
    let root = json::read_any_encoding(payload).ok_or(ClientMessageFailure::Malformed)?;
    // `get` answers only an object's members, so an array root is malformed.
    let kind = root
        .get("type")
        .and_then(JsonValue::as_str)
        .ok_or(ClientMessageFailure::Malformed)?;
    match kind {
        "hello" => {
            let token = root
                .get("token")
                .and_then(JsonValue::as_str)
                .filter(|token| !token.is_empty())
                .ok_or(ClientMessageFailure::BadHello)?;
            let requested = requested_version(root.get("protocol"));
            if requested != PROTOCOL_VERSION {
                return Err(ClientMessageFailure::UnsupportedProtocol(requested));
            }
            Ok(ClientMessage::Hello {
                token: token.to_owned(),
            })
        }
        "intent" => {
            let name = root.get("intent").and_then(JsonValue::as_str).unwrap_or("");
            let text = root.get("text").and_then(JsonValue::as_str);
            intent_for_protocol_name(name, text)
                .map(ClientMessage::Intent)
                .ok_or_else(|| ClientMessageFailure::UnknownIntent(name.to_owned()))
        }
        "ping" => Ok(ClientMessage::Ping),
        other => Err(ClientMessageFailure::UnknownType(other.to_owned())),
    }
}

/// A hello's `protocol` as Swift read it, `(as? NSNumber)?.intValue ?? 0`:
/// a bool is 1 or 0; a string, null or anything else is ignored (0).
fn requested_version(value: Option<&JsonValue>) -> i64 {
    match value {
        Some(JsonValue::Bool(flag)) => i64::from(*flag),
        Some(JsonValue::Number(number)) => int_value(number),
        _ => PROTOCOL_VERSION,
    }
}

/// `NSNumber.intValue` of a number `JSONSerialization` read (measured on
/// macOS 27.2, client-message.json): an integer literal inside `Int` is
/// itself; one inside `UInt64` only (2^63 up) is an unsigned NSNumber whose
/// `intValue` wraps, so 2^63 reads as `Int.min`; a longer one is an
/// NSDecimalNumber whose `intValue` is 0 (2^64). A literal with a fraction
/// or an exponent is a double, truncated toward zero and saturated at
/// `Int`'s bounds (0.5 is 0, 1.9 is 1, 1e30 is `Int.max`). A literal of
/// more than 17 significant digits with a fraction or exponent, which
/// Foundation reads as an NSDecimalNumber, is read through its double here,
/// an unmeasured difference no client sends.
fn int_value(number: &JsonNumber) -> i64 {
    let literal = &*number.literal;
    if literal.contains(['.', 'e', 'E']) {
        // `as` truncates toward zero and saturates, as intValue does with a
        // double.
        #[allow(clippy::cast_possible_truncation)]
        return number.value as i64;
    }
    if let Ok(value) = literal.parse::<i64>() {
        return value;
    }
    literal.parse::<u64>().map_or(0, u64::cast_signed)
}

/// The intent a protocol client may send by this wire name (HK-226,
/// HK-227, HK-228), or `None` when the name is refused, which the server
/// answers with `unknown_intent`, never by acting.
///
/// Sixteen exact, case-sensitive names; `sendPrompt` needs `text` that is
/// not empty once trimmed of `.whitespacesAndNewlines`, and its prompt is
/// the trimmed text; every other name ignores `text`. Deliberately a
/// subset of [`Intent`]: no voice capture (the microphone is local to the
/// app; a client sends text through sendPrompt), and no name grants what a
/// controller cannot already do: the permission mode is reachable only
/// through cyclePermissionMode, whose fixed cycle excludes
/// bypassPermissions. Growing this table is a reviewed decision.
pub fn intent_for_protocol_name(name: &str, text: Option<&str>) -> Option<Intent> {
    Some(match name {
        "sendPrompt" => {
            let prompt = trim(text?);
            if prompt.is_empty() {
                return None;
            }
            Intent::SendPrompt(prompt.to_owned())
        }
        "sendDraft" => Intent::SendDraft,
        "approve" => Intent::Approve,
        "reject" => Intent::Reject,
        "interrupt" => Intent::Interrupt,
        "stopSpeaking" => Intent::StopSpeaking,
        "replayLastReply" => Intent::ReplayLastReply,
        "toggleTTS" => Intent::ToggleTts,
        "newSession" => Intent::NewSession,
        "showWindow" => Intent::ShowWindow,
        "cycleModel" => Intent::CycleModel,
        "cycleEffort" => Intent::CycleEffort,
        "cyclePermissionMode" => Intent::CyclePermissionMode,
        "cycleProject" => Intent::CycleProject,
        "cycleFocus" => Intent::CycleFocus,
        "toggleControlMode" => Intent::ToggleControlMode,
        _ => return None,
    })
}

/// The session facts a `session` message carries (HK-232).
#[derive(Debug, Clone, PartialEq)]
pub struct SessionMessage {
    /// The configured alias; `"default"` means the adapter decides.
    pub model: String,
    /// What the running session reports, when known.
    pub live_model: Option<String>,
    pub effort: String,
    pub permission_mode: String,
    pub control_mode: String,
    pub session_id: Option<String>,
    pub cost_usd: f64,
    /// Tokens used so far; 0 (or less) when the harness reports none.
    pub tokens: i64,
}

/// A message the server sends.
#[derive(Debug, Clone, PartialEq)]
pub enum ServerMessage {
    /// After a successful hello (HK-234).
    Welcome {
        app_version: String,
    },
    Status(AppStatus),
    Transcript(TranscriptEntry),
    Session(SessionMessage),
    /// The answer to a client's ping message.
    Pong,
    Error {
        code: String,
        message: String,
    },
}

impl ServerMessage {
    /// An error message with one of the contract's codes.
    pub fn error(code: ErrorCode, message: &str) -> ServerMessage {
        ServerMessage::Error {
            code: code.name().to_owned(),
            message: message.to_owned(),
        }
    }

    /// The error message a refused client message is answered with.
    pub fn failure(failure: &ClientMessageFailure) -> ServerMessage {
        ServerMessage::Error {
            code: failure.code().name().to_owned(),
            message: failure.message(),
        }
    }
}

/// The text of `message`'s frame: one compact JSON object with no
/// whitespace, so never a raw newline (HK-233), or `None` when it holds a
/// number JSON cannot spell (a NaN or infinite cost or date), which Swift's
/// `JSONSerialization` refused to write and the listener never sends.
///
/// The members, in the order this writes them (Swift's was a hash order
/// that changed from launch to launch, so the core fixes one): welcome is
/// type, protocol, app, version (HK-234); status is type and the fixed
/// status name (HK-230); transcript is type and entry, the entry id
/// (uppercase, as `uuidString` spells it), kind, text and date in Unix
/// seconds, not ISO 8601 (HK-231); session is type, model, effort,
/// permissionMode, controlMode and costUSD, then tokens only above zero
/// and liveModel and sessionID only when present and not empty (HK-232);
/// pong is type; error is type, code, message. Strings are escaped as
/// Foundation escapes them (`/` as `\/`, the C0 controls; DEL and non-ASCII
/// raw), integers are decimal and a Double is written as `%.17g` writes it.
pub fn encode(message: &ServerMessage) -> Option<String> {
    let mut object = ObjectText::new("type", type_name(message))?;
    match message {
        ServerMessage::Welcome { app_version } => {
            object.raw("protocol", &PROTOCOL_VERSION.to_string());
            object.string("app", APP_NAME)?;
            object.string("version", app_version)?;
        }
        ServerMessage::Status(status) => object.string("status", status.name())?,
        ServerMessage::Transcript(entry) => {
            let mut fields = ObjectText::new("id", &entry.id.to_ascii_uppercase())?;
            fields.string("kind", entry.kind.name())?;
            fields.string("text", &entry.text)?;
            fields.raw("date", &serialization_double(entry.date_seconds)?);
            object.raw("entry", &fields.finish());
        }
        ServerMessage::Session(session) => {
            object.string("model", &session.model)?;
            object.string("effort", &session.effort)?;
            object.string("permissionMode", &session.permission_mode)?;
            object.string("controlMode", &session.control_mode)?;
            object.raw("costUSD", &serialization_double(session.cost_usd)?);
            if session.tokens > 0 {
                object.raw("tokens", &session.tokens.to_string());
            }
            if let Some(live_model) = session.live_model.as_deref().filter(|m| !m.is_empty()) {
                object.string("liveModel", live_model)?;
            }
            if let Some(session_id) = session.session_id.as_deref().filter(|id| !id.is_empty()) {
                object.string("sessionID", session_id)?;
            }
        }
        ServerMessage::Pong => {}
        ServerMessage::Error { code, message } => {
            object.string("code", code)?;
            object.string("message", message)?;
        }
    }
    Some(object.finish())
}

fn type_name(message: &ServerMessage) -> &'static str {
    match message {
        ServerMessage::Welcome { .. } => "welcome",
        ServerMessage::Status(_) => "status",
        ServerMessage::Transcript(_) => "transcript",
        ServerMessage::Session(_) => "session",
        ServerMessage::Pong => "pong",
        ServerMessage::Error { .. } => "error",
    }
}

/// A compact JSON object written member by member.
struct ObjectText(String);

impl ObjectText {
    fn new(key: &str, value: &str) -> Option<ObjectText> {
        let mut object = ObjectText(String::from("{"));
        object.string(key, value)?;
        Some(object)
    }

    fn raw(&mut self, key: &str, value: &str) {
        if self.0.len() > 1 {
            self.0.push(',');
        }
        // A key is one of this module's ASCII names.
        self.0.push('"');
        self.0.push_str(key);
        self.0.push_str("\":");
        self.0.push_str(value);
    }

    fn string(&mut self, key: &str, value: &str) -> Option<()> {
        let quoted = wire::to_swift_json(value).ok()?;
        self.raw(key, &quoted);
        Some(())
    }

    fn finish(mut self) -> String {
        self.0.push('}');
        self.0
    }
}

/// A Double as `JSONSerialization` writes it, which is C's `%.17g`: 17
/// significant digits, correctly rounded (ties to even), trailing zeros and
/// a bare point dropped, in positional form when the decimal exponent is
/// from -4 to 16 and as `d.ddde±XX` otherwise (at least two exponent
/// digits). So 0.0421 is `0.042099999999999999` and 1e-7 is
/// `9.9999999999999995e-08`, not the shortest round-trip digits
/// `JSONEncoder` writes (`json::encoder::swift_f64`); -0 is `-0`. `None`
/// for NaN and the infinities.
fn serialization_double(value: f64) -> Option<String> {
    if !value.is_finite() {
        return None;
    }
    if value == 0.0 {
        return Some(if value.is_sign_negative() { "-0" } else { "0" }.to_owned());
    }
    // Rust's exact formatting rounds ties to even, as printf does.
    let scientific = format!("{:.16e}", value.abs());
    let (mantissa, exponent) = scientific.split_once('e')?;
    let exponent: i32 = exponent.parse().ok()?;
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if value.is_sign_negative() { "-" } else { "" };

    if !(-4..17).contains(&exponent) {
        let (first, rest) = digits.split_at_checked(1)?;
        let rest = rest.trim_end_matches('0');
        let point = if rest.is_empty() { "" } else { "." };
        let exponent_sign = if exponent < 0 { '-' } else { '+' };
        return Some(format!(
            "{sign}{first}{point}{rest}e{exponent_sign}{:02}",
            exponent.unsigned_abs()
        ));
    }
    let (whole, fraction) = if exponent >= 0 {
        let split = usize::try_from(exponent).ok()? + 1;
        let (whole, fraction) = digits.split_at_checked(split)?;
        (whole.to_owned(), fraction.to_owned())
    } else {
        let zeros = "0".repeat(usize::try_from(-exponent - 1).ok()?);
        ("0".to_owned(), format!("{zeros}{digits}"))
    };
    let fraction = fraction.trim_end_matches('0');
    if fraction.is_empty() {
        Some(format!("{sign}{whole}"))
    } else {
        Some(format!("{sign}{whole}.{fraction}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_are_written_as_printf_17g() {
        for (value, text) in [
            (0.0421, "0.042099999999999999"),
            (1e-7, "9.9999999999999995e-08"),
            (1e21, "1e+21"),
            (1e16, "10000000000000000"),
            (1e17, "1e+17"),
            (0.0001, "0.0001"),
            (1e-5, "1.0000000000000001e-05"),
            (-0.5, "-0.5"),
            (12.5, "12.5"),
            (1e300, "1.0000000000000001e+300"),
            (5e-324, "4.9406564584124654e-324"),
            (f64::MAX, "1.7976931348623157e+308"),
            // 2^50 + 0.25: a tie at the 17th digit rounds to even.
            (1_125_899_906_842_624.0 + 0.25, "1125899906842624.2"),
        ] {
            assert_eq!(
                serialization_double(value).as_deref(),
                Some(text),
                "{value:e}"
            );
        }
        assert_eq!(serialization_double(-0.0).as_deref(), Some("-0"));
        assert_eq!(serialization_double(f64::NAN), None);
        assert_eq!(serialization_double(f64::NEG_INFINITY), None);
    }

    #[test]
    fn random_payloads_never_panic() {
        let mut state: u64 = 0x0123_4567_89AB_CDEF;
        let alphabet: &[u8] =
            b"{}[]\":,0123456789.eE-+ \x00\xFE\xFF\xEF\xBB\xBFtypehellotokenintentping";
        for _ in 0..5000 {
            let length = usize::from(state.to_le_bytes()[2] % 48);
            let bytes: Vec<u8> = (0..length)
                .map(|_| {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    alphabet[usize::from(state.to_le_bytes()[0]) % alphabet.len()]
                })
                .collect();
            if let Err(failure) = parse_client_message(&bytes) {
                assert!(encode(&ServerMessage::failure(&failure)).is_some());
            }
        }
    }

    #[test]
    fn every_listener_error_is_one_line() {
        for (code, message) in [
            (ErrorCode::AuthFailed, AUTH_FAILED_MESSAGE),
            (ErrorCode::NotAuthenticated, NOT_AUTHENTICATED_MESSAGE),
            (ErrorCode::ServerBusy, SERVER_BUSY_MESSAGE),
        ] {
            let text = encode(&ServerMessage::error(code, message)).unwrap();
            assert!(!text.contains('\n'));
            assert!(text.starts_with("{\"type\":\"error\",\"code\":\""));
        }
    }
}
