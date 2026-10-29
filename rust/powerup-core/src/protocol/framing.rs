//! Server-side RFC 6455 frames with the protocol's v0 limits (DESIGN v1.7,
//! `docs/protocol.md` "Transport"): text frames at the application layer,
//! no fragmentation (a non-final data frame is a protocol violation), and a
//! payload ceiling the caller passes (the listener's is 1 MB). Ported from
//! the Swift app's `WebSocketFraming` rule for rule;
//! `Tests/Fixtures/protocol/frame-decode.json` and `frame-encode.json` pin
//! every byte.

/// A frame's opcode (RFC 6455 section 5.2). The others (0x3 to 0x7, 0xB to
/// 0xF) are reserved and refused (HK-239).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Opcode {
    Continuation,
    Text,
    Binary,
    Close,
    Ping,
    Pong,
}

impl Opcode {
    /// The opcode the low four bits of a frame's first byte name, or `None`
    /// for a reserved one.
    pub fn from_bits(bits: u8) -> Option<Opcode> {
        Some(match bits {
            0x0 => Opcode::Continuation,
            0x1 => Opcode::Text,
            0x2 => Opcode::Binary,
            0x8 => Opcode::Close,
            0x9 => Opcode::Ping,
            0xA => Opcode::Pong,
            _ => return None,
        })
    }

    /// The opcode's four bits.
    pub fn bits(self) -> u8 {
        match self {
            Opcode::Continuation => 0x0,
            Opcode::Text => 0x1,
            Opcode::Binary => 0x2,
            Opcode::Close => 0x8,
            Opcode::Ping => 0x9,
            Opcode::Pong => 0xA,
        }
    }

    /// The Swift case name, which the fixtures use.
    pub fn name(self) -> &'static str {
        match self {
            Opcode::Continuation => "continuation",
            Opcode::Text => "text",
            Opcode::Binary => "binary",
            Opcode::Close => "close",
            Opcode::Ping => "ping",
            Opcode::Pong => "pong",
        }
    }
}

/// One decoded client frame, its payload unmasked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub opcode: Opcode,
    pub payload: Vec<u8>,
}

/// What [`decode_frames`] found at the head of a buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedFrames {
    /// Every complete frame, in order.
    pub frames: Vec<Frame>,
    /// How many bytes those frames took; the caller drops them and keeps
    /// the rest, a partial frame, for the next chunk (HK-242).
    pub consumed: usize,
}

/// A buffer that breaks v0's framing rules: malformed, unmasked,
/// fragmented, oversized, or with a reserved opcode or bit. The listener
/// closes the connection with [`close_code::PROTOCOL_ERROR`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolViolation;

/// The largest payload a control frame (close, ping, pong) may carry.
const MAX_CONTROL_PAYLOAD: u8 = 125;

/// The close codes the listener sends (HK-244). Each is the 2-byte payload
/// of [`encode_close`]; the 4xxx codes tell a client why it was dropped.
pub mod close_code {
    /// The answer to a client's own close (HK-258).
    pub const NORMAL: u16 = 1000;
    /// A framing violation, or a `malformed`, `bad_hello` or
    /// `unsupported_protocol` message (HK-224, HK-225: never 1007 for text
    /// that is not UTF-8).
    pub const PROTOCOL_ERROR: u16 = 1002;
    /// A binary frame (HK-239).
    pub const UNSUPPORTED_DATA: u16 = 1003;
    /// A receive buffer past its ceiling (HK-259).
    pub const MESSAGE_TOO_BIG: u16 = 1009;
    /// `server_busy`: the authenticated client cap is reached (HK-261).
    pub const TRY_AGAIN_LATER: u16 = 1013;
    /// `auth_failed`: the hello carried the wrong token (HK-257).
    pub const AUTH_FAILED: u16 = 4001;
    /// `not_authenticated`: an intent came before the hello (HK-257).
    pub const NOT_AUTHENTICATED: u16 = 4003;
}

/// Decodes every complete frame at the head of `buffer`.
///
/// From the start, while at least two bytes remain, in this order: the RSV
/// bits must be zero (HK-237), the opcode known (HK-239), the mask bit set
/// (client frames must be masked, HK-236); a control frame must be final
/// with a 7-bit length of at most 125, a data frame final and not a
/// continuation (v0 has no reassembly, HK-238). A 7-bit length of 126 is
/// followed by a 2-byte big-endian length and 127 by an 8-byte one, each
/// read once all its bytes are present (HK-241); non-minimal encodings are
/// accepted. The length is checked against `max_payload` as the 64-bit
/// value it is, before any conversion, so a hostile length can neither
/// overflow nor wait for a payload that never comes (HK-240). A frame is
/// decoded once its 4-byte mask key and whole payload are present.
///
/// Any violation refuses the whole buffer: the frames decoded before it in
/// the same call are not returned and nothing is consumed, as the Swift
/// listener did (a hello followed by a bad frame in one chunk is never
/// read). Text payloads are not checked as UTF-8 here (HK-225).
pub fn decode_frames(
    buffer: &[u8],
    max_payload: usize,
) -> Result<DecodedFrames, ProtocolViolation> {
    let max_payload = u64::try_from(max_payload).unwrap_or(u64::MAX);
    let mut frames = Vec::new();
    let mut offset = 0;
    while let Some(rest) = buffer.get(offset..) {
        let [first, second, ..] = *rest else {
            break;
        };
        if first & 0x70 != 0 {
            return Err(ProtocolViolation);
        }
        let opcode = Opcode::from_bits(first & 0x0F).ok_or(ProtocolViolation)?;
        if second & 0x80 == 0 {
            return Err(ProtocolViolation);
        }
        let fin = first & 0x80 != 0;
        let short_length = second & 0x7F;
        let is_control = first & 0x08 != 0;
        let allowed = if is_control {
            fin && short_length <= MAX_CONTROL_PAYLOAD
        } else {
            fin && opcode != Opcode::Continuation
        };
        if !allowed {
            return Err(ProtocolViolation);
        }

        let (header_length, payload_length): (usize, u64) = match short_length {
            126 => {
                let Some(&[high, low]) = rest.get(2..4) else {
                    break;
                };
                (4, u64::from(u16::from_be_bytes([high, low])))
            }
            127 => {
                let Some(Ok(length)) = rest.get(2..10).map(<[u8; 8]>::try_from) else {
                    break;
                };
                (10, u64::from_be_bytes(length))
            }
            short => (2, u64::from(short)),
        };
        if payload_length > max_payload {
            return Err(ProtocolViolation);
        }
        let payload_length = usize::try_from(payload_length).map_err(|_| ProtocolViolation)?;

        // The header, the mask key, the payload.
        let total = (header_length + 4).saturating_add(payload_length);
        let Some(frame) = rest.get(..total) else {
            break;
        };
        let (Some(mask), Some(masked)) = (
            frame.get(header_length..header_length + 4),
            frame.get(header_length + 4..),
        ) else {
            break;
        };
        let payload = masked
            .iter()
            .zip(mask.iter().cycle())
            .map(|(byte, key)| byte ^ key)
            .collect();
        frames.push(Frame { opcode, payload });
        offset += total;
    }
    Ok(DecodedFrames {
        frames,
        consumed: offset,
    })
}

/// One final, unmasked server frame (a server never masks, HK-243): the
/// first byte 0x80 plus the opcode, then the length in the second byte
/// below 126, as 126 and a 2-byte big-endian length up to 65535, and as
/// 127 and an 8-byte big-endian length beyond, then the payload.
pub fn encode_frame(opcode: Opcode, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(payload.len().saturating_add(10));
    frame.push(0x80 | opcode.bits());
    let length = payload.len();
    if let Ok(short @ 0..=125) = u8::try_from(length) {
        frame.push(short);
    } else if let Ok(medium) = u16::try_from(length) {
        frame.push(126);
        frame.extend_from_slice(&medium.to_be_bytes());
    } else {
        frame.push(127);
        frame.extend_from_slice(&u64::try_from(length).unwrap_or(u64::MAX).to_be_bytes());
    }
    frame.extend_from_slice(payload);
    frame
}

/// A text frame carrying `payload`.
pub fn encode_text(payload: &[u8]) -> Vec<u8> {
    encode_frame(Opcode::Text, payload)
}

/// A close frame whose payload is `code`, big-endian, with no reason text
/// (HK-244).
pub fn encode_close(code: u16) -> Vec<u8> {
    encode_frame(Opcode::Close, &code.to_be_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny deterministic generator, so the property tests need no crate.
    struct Bytes(u64);

    impl Bytes {
        fn next(&mut self) -> u8 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0.to_le_bytes()[0]
        }
    }

    fn masked(opcode: Opcode, payload: &[u8]) -> Vec<u8> {
        let mut frame = encode_frame(opcode, payload);
        let header = frame.len() - payload.len();
        frame[1] |= 0x80;
        let key = [0x11, 0x22, 0x33, 0x44];
        let mut out = frame[..header].to_vec();
        out.extend_from_slice(&key);
        out.extend(payload.iter().zip(key.iter().cycle()).map(|(b, k)| b ^ k));
        out
    }

    #[test]
    fn every_opcode_round_trips_its_bits() {
        for bits in 0..=0x0F {
            if let Some(opcode) = Opcode::from_bits(bits) {
                assert_eq!(opcode.bits(), bits);
            }
        }
    }

    #[test]
    fn random_and_truncated_buffers_never_panic() {
        let mut random = Bytes(0x9E37_79B9_7F4A_7C15);
        for length in 0..600 {
            let buffer: Vec<u8> = (0..length % 40).map(|_| random.next()).collect();
            for max in [0, 1, 125, 1 << 20, usize::MAX] {
                if let Ok(decoded) = decode_frames(&buffer, max) {
                    assert!(decoded.consumed <= buffer.len());
                }
            }
        }
    }

    #[test]
    fn every_prefix_of_a_valid_chunk_waits_or_decodes() {
        let mut chunk = masked(Opcode::Text, b"{\"type\":\"ping\"}");
        chunk.extend(masked(Opcode::Ping, b"abc"));
        chunk.extend(masked(Opcode::Text, &[b'a'; 300]));
        chunk.extend(masked(Opcode::Binary, &[b'b'; 70_000]));
        for end in 0..=chunk.len() {
            let decoded = decode_frames(&chunk[..end], 1 << 20).unwrap();
            let payloads: usize = decoded.frames.iter().map(|f| f.payload.len()).sum();
            assert!(decoded.consumed <= end && payloads <= decoded.consumed);
        }
        let all = decode_frames(&chunk, 1 << 20).unwrap();
        assert_eq!(all.consumed, chunk.len());
        assert_eq!(all.frames.len(), 4);
        assert_eq!(all.frames[3].payload, vec![b'b'; 70_000]);
    }
}
