//! The request head on the listener port and the WebSocket upgrade
//! decision (DESIGN v1.4, v1.7; `docs/protocol.md` "Transport" and
//! "Security"). One port serves both the hook posts (`POST /event`) and
//! the protocol (`GET /ws`), so every connection starts as HTTP: its head is
//! found ([`header_boundary`]), read ([`RequestHead::parse`]) and, for
//! `/ws`, either upgraded with the accept key ([`accept_key`]) or refused
//! with a status. Ported from the Swift listener's `RequestHead` and
//! `PowerUpProtocol.upgradeDecision`, including how Swift's `String` and
//! Foundation read the text; `Tests/Fixtures/protocol/handshake.json` and
//! `accept-key.json` pin them.

use unicode_segmentation::UnicodeSegmentation;

use crate::sha1;
use crate::text::{contains_clusters, lowercase_scalars, split_on_spaces, trim_whitespaces};

/// RFC 6455 section 4.2.2's handshake GUID.
pub const HANDSHAKE_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Where a request's header block ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeaderBoundary {
    /// The length of the header block, its terminator excluded.
    pub header_end: usize,
    /// Where the body (or, after an upgrade, the WebSocket stream) begins.
    pub body_start: usize,
}

/// The end of the header block at the head of `bytes`: the first CR LF CR
/// LF or LF LF, whichever starts first, or `None` while neither has
/// arrived. Bare LF is tolerated because a real hook script sent it
/// (HK-254). A bare-LF block that ends in a CR LF blank line (`\n\r\n`) is
/// not recognised, as in the Swift listener: the connection waits for more.
pub fn header_boundary(bytes: &[u8]) -> Option<HeaderBoundary> {
    let mut index = 0;
    while index + 1 < bytes.len() {
        if bytes.get(index..index + 4) == Some(b"\r\n\r\n") {
            return Some(HeaderBoundary {
                header_end: index,
                body_start: index + 4,
            });
        }
        if bytes.get(index..index + 2) == Some(b"\n\n") {
            return Some(HeaderBoundary {
                header_end: index,
                body_start: index + 2,
            });
        }
        index += 1;
    }
    None
}

/// A request's method, path and headers, read as the Swift listener read
/// them (HK-254).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestHead {
    /// The method, uppercased (each scalar's full uppercase mapping, as
    /// Swift's `uppercased()`).
    pub method: String,
    /// The request target up to its first `?`; nothing else is decoded or
    /// cut (a fragment, a percent escape and an absolute form stay).
    pub path: String,
    /// Every header in order, its name lowercased; [`RequestHead::value`]
    /// answers the last of equal names.
    headers: Vec<(String, String)>,
}

impl RequestHead {
    /// Reads a header block (the bytes before [`HeaderBoundary::header_end`]),
    /// or `None` when it has no request line of at least two parts (the
    /// listener answers 400).
    ///
    /// The bytes are read as UTF-8 with each invalid sequence replaced by
    /// U+FFFD, then split into lines at LF with one trailing CR dropped
    /// from each, so a line ending in CR CR keeps one CR. The request line
    /// splits on runs of characters equal to a space (a tab is no
    /// separator; the version is not read). A header line splits at its
    /// first character equal to a colon; the name is trimmed of
    /// `.whitespaces` and lowercased scalar by scalar, the value trimmed;
    /// a line without a colon or with an empty name is skipped, and a
    /// folded line is not joined to the one before.
    pub fn parse(head: &[u8]) -> Option<RequestHead> {
        let text = String::from_utf8_lossy(head);
        let mut lines = text
            .split('\n')
            .map(|line| line.strip_suffix('\r').unwrap_or(line));
        let request_line = lines.next()?;
        let (method, target) = match split_on_spaces(request_line).as_slice() {
            [method, target, ..] => (method.to_uppercase(), *target),
            _ => return None,
        };
        let path = before_first_cluster(target, "?").to_owned();

        let headers = lines
            .filter(|line| !line.is_empty())
            .filter_map(|line| {
                let at = line
                    .grapheme_indices(true)
                    .find(|(_, cluster)| *cluster == ":")
                    .map(|(at, _)| at)?;
                let name = lowercase_scalars(trim_whitespaces(line.get(..at)?));
                let value = trim_whitespaces(line.get(at + 1..)?).to_owned();
                (!name.is_empty()).then_some((name, value))
            })
            .collect();
        Some(RequestHead {
            method,
            path,
            headers,
        })
    }

    /// The value of the last header called `name` (any case). Swift's
    /// dictionary compared names by canonical equivalence and this compares
    /// their text; the two agree for the ASCII names the listener looks up,
    /// which once lowercased are equivalent only to themselves.
    pub fn value(&self, name: &str) -> Option<&str> {
        let name = lowercase_scalars(name);
        self.headers
            .iter()
            .rev()
            .find(|(header, _)| *header == name)
            .map(|(_, value)| value.as_str())
    }

    /// `Content-Length` as Swift's `Int(String)` reads it once trimmed: an
    /// optional sign and ASCII digits inside `Int`'s range. Anything else,
    /// a missing header included, is `None`, which the listener treats as
    /// no body; a negative length is the listener's to refuse.
    pub fn content_length(&self) -> Option<i64> {
        trim_whitespaces(self.value("content-length")?).parse().ok()
    }

    /// Whether `Transfer-Encoding` names chunked (the body is then read to
    /// the end of the stream, never decoded, HK-251).
    pub fn is_chunked(&self) -> bool {
        self.lowercase_value_contains("transfer-encoding", "chunked")
    }

    /// Whether the client sent `Expect: 100-continue` (HK-250).
    pub fn expects_continue(&self) -> bool {
        self.lowercase_value_contains("expect", "100-continue")
    }

    fn lowercase_value_contains(&self, name: &str, needle: &str) -> bool {
        contains_clusters(&lowercase_scalars(self.value(name).unwrap_or("")), needle)
    }
}

/// What to do with a request for the WebSocket endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpgradeDecision {
    /// Switch protocols, answering with this `Sec-WebSocket-Accept`.
    Accept { accept_key: String },
    /// Answer with this status and reason and close.
    Reject { status: u16, reason: &'static str },
}

/// The decision for a request, or `None` when its path is not exactly
/// `/ws` (plain HTTP handling carries on: the hook posts share the port,
/// HK-218). Otherwise the first failing check wins, in this order:
/// a method other than GET is 405; an `Upgrade` value that does not
/// contain `websocket` or a `Connection` value that does not contain
/// `upgrade`, both lowercased, is 400 (HK-220); any `Origin` that is not
/// empty once trimmed is 403, because browsers always send one and the
/// cross-site WebSocket hijacking door stays shut until an allowlist is
/// designed (HK-219); a `Sec-WebSocket-Version` other than exactly `13` is
/// 426 (HK-221); a `Sec-WebSocket-Key` empty once trimmed is 400 (HK-222).
/// The key is never checked as base64 or for its length.
pub fn upgrade_decision(head: &RequestHead) -> Option<UpgradeDecision> {
    if head.path != "/ws" {
        return None;
    }
    let reject = |status, reason| Some(UpgradeDecision::Reject { status, reason });
    if head.method != "GET" {
        return reject(405, "Method Not Allowed");
    }
    if !head.lowercase_value_contains("upgrade", "websocket")
        || !head.lowercase_value_contains("connection", "upgrade")
    {
        return reject(400, "Bad Request");
    }
    if head
        .value("origin")
        .is_some_and(|origin| !trim_whitespaces(origin).is_empty())
    {
        return reject(403, "Forbidden");
    }
    if head.value("sec-websocket-version") != Some("13") {
        return reject(426, "Upgrade Required");
    }
    match head.value("sec-websocket-key").map(trim_whitespaces) {
        Some(key) if !key.is_empty() => Some(UpgradeDecision::Accept {
            accept_key: accept_key(key),
        }),
        _ => reject(400, "Bad Request"),
    }
}

/// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (HK-235):
/// the standard base64, with `=` padding, of the SHA-1 digest of the key's
/// UTF-8 bytes followed by [`HANDSHAKE_GUID`].
pub fn accept_key(client_key: &str) -> String {
    let mut message = client_key.as_bytes().to_vec();
    message.extend_from_slice(HANDSHAKE_GUID.as_bytes());
    base64(&sha1::digest(&message))
}

/// The text before the first character equal to `separator`, or all of it
/// (Swift's `split(separator:maxSplits: 1, omittingEmptySubsequences:
/// false).first`): a separator that a combining mark follows is another
/// character.
fn before_first_cluster<'a>(text: &'a str, separator: &str) -> &'a str {
    text.grapheme_indices(true)
        .find(|(_, cluster)| *cluster == separator)
        .and_then(|(at, _)| text.get(..at))
        .unwrap_or(text)
}

/// Standard base64 (RFC 4648 section 4) with `=` padding.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let symbol = |index: u32| {
        // Six bits: always inside the alphabet.
        char::from(ALPHABET[(index & 0x3F) as usize])
    };
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let [first, second, third] = [0, 1, 2].map(|at| chunk.get(at).copied().unwrap_or(0));
        let group = u32::from(first) << 16 | u32::from(second) << 8 | u32::from(third);
        out.push(symbol(group >> 18));
        out.push(symbol(group >> 12));
        out.push(if chunk.len() > 1 {
            symbol(group >> 6)
        } else {
            '='
        });
        out.push(if chunk.len() > 2 { symbol(group) } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_follows_rfc_4648() {
        // RFC 4648 section 10.
        for (input, output) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(input.as_bytes()), output);
        }
        assert_eq!(base64(&[0xFB, 0xFF]), "+/8=");
    }

    #[test]
    fn content_length_reads_like_swift_int() {
        let head = |value: &str| {
            RequestHead::parse(format!("POST /event HTTP/1.1\r\nContent-Length:{value}").as_bytes())
                .unwrap()
        };
        assert_eq!(head(" 42 ").content_length(), Some(42));
        assert_eq!(head("+5").content_length(), Some(5));
        assert_eq!(head("-1").content_length(), Some(-1));
        assert_eq!(head("4x").content_length(), None);
        assert_eq!(head("").content_length(), None);
        assert_eq!(head("99999999999999999999").content_length(), None);
        assert_eq!(head("4 2").content_length(), None);
        assert_eq!(
            RequestHead::parse(b"POST /event HTTP/1.1")
                .unwrap()
                .content_length(),
            None
        );
    }

    #[test]
    fn chunked_and_continue_are_found_in_any_case() {
        let head = RequestHead::parse(
            b"POST /event HTTP/1.1\nTransfer-Encoding: gzip, CHUNKED\nExpect: 100-Continue",
        )
        .unwrap();
        assert!(head.is_chunked() && head.expects_continue());
        let plain = RequestHead::parse(b"POST /event HTTP/1.1\nHost: x").unwrap();
        assert!(!plain.is_chunked() && !plain.expects_continue());
    }

    #[test]
    fn a_combining_mark_hides_a_separator() {
        // A space, colon or question mark that a combining acute follows is
        // another character to Swift, so it separates nothing.
        let head =
            RequestHead::parse("GET /ws?\u{301}x HTTP/1.1\nX-A:\u{301}b: c".as_bytes()).unwrap();
        assert_eq!(head.path, "/ws?\u{301}x");
        assert_eq!(head.value("x-a:\u{301}b"), Some("c"));
        let joined = RequestHead::parse("GET \u{301}/ws HTTP/1.1".as_bytes()).unwrap();
        assert_eq!(joined.method, "GET \u{301}/WS");
        assert_eq!(joined.path, "HTTP/1.1");
    }

    #[test]
    fn random_heads_never_panic() {
        let mut state: u64 = 0x2545_F491_4F6C_DD1D;
        let alphabet: &[u8] = b"GETPOST /ws?:\r\n\t \xC3\xA9\xFF\xCC\x81Origin13";
        for _ in 0..3000 {
            let length = usize::from(state.to_le_bytes()[1] % 64);
            let bytes: Vec<u8> = (0..length)
                .map(|_| {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    alphabet[usize::from(state.to_le_bytes()[0]) % alphabet.len()]
                })
                .collect();
            if let Some(boundary) = header_boundary(&bytes) {
                assert!(boundary.header_end < boundary.body_start);
                assert!(boundary.body_start <= bytes.len());
            }
            if let Some(head) = RequestHead::parse(&bytes) {
                let _ = upgrade_decision(&head);
                let _ = head.content_length();
            }
        }
    }
}
