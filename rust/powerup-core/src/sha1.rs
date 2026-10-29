//! SHA-1 (FIPS 180-4) over a byte slice, for the WebSocket handshake's
//! `Sec-WebSocket-Accept` value (RFC 6455 section 4.2.2, HK-235), which the
//! Swift listener computed with CryptoKit's `Insecure.SHA1`. SHA-1 is broken
//! for signatures, but the handshake only proves that the server read the
//! client's key; one short function keeps a hashing crate and its
//! dependencies out of the core, as `sha256` does.

const INITIAL_STATE: [u32; 5] = [
    0x6745_2301,
    0xefcd_ab89,
    0x98ba_dcfe,
    0x1032_5476,
    0xc3d2_e1f0,
];

/// The 20-byte digest of `message`.
pub(crate) fn digest(message: &[u8]) -> [u8; 20] {
    // The message, a 1 bit, zeros up to 56 bytes mod 64, then its length in
    // bits as a big-endian u64.
    let mut padded = message.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    let bits = u64::try_from(message.len())
        .unwrap_or(u64::MAX)
        .wrapping_mul(8);
    padded.extend_from_slice(&bits.to_be_bytes());

    let mut state = INITIAL_STATE;
    for block in padded.as_chunks::<64>().0 {
        compress(&mut state, block);
    }
    let mut out = [0u8; 20];
    for (bytes, word) in out.as_chunks_mut::<4>().0.iter_mut().zip(state) {
        *bytes = word.to_be_bytes();
    }
    out
}

fn compress(state: &mut [u32; 5], block: &[u8; 64]) {
    let mut schedule = [0u32; 80];
    for (word, bytes) in schedule.iter_mut().zip(block.as_chunks::<4>().0) {
        *word = u32::from_be_bytes(*bytes);
    }
    for t in 16..80 {
        schedule[t] = (schedule[t - 3] ^ schedule[t - 8] ^ schedule[t - 14] ^ schedule[t - 16])
            .rotate_left(1);
    }

    let [mut a, mut b, mut c, mut d, mut e] = *state;
    for (t, word) in schedule.into_iter().enumerate() {
        let (mixed, constant) = match t {
            0..=19 => ((b & c) | (!b & d), 0x5a82_7999),
            20..=39 => (b ^ c ^ d, 0x6ed9_eba1),
            40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1b_bcdc),
            _ => (b ^ c ^ d, 0xca62_c1d6),
        };
        let next = a
            .rotate_left(5)
            .wrapping_add(mixed)
            .wrapping_add(e)
            .wrapping_add(constant)
            .wrapping_add(word);
        e = d;
        d = c;
        c = b.rotate_left(30);
        b = a;
        a = next;
    }
    for (word, add) in state.iter_mut().zip([a, b, c, d, e]) {
        *word = word.wrapping_add(add);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn nist_vectors() {
        // FIPS 180-4 examples and the NIST short and long message vectors.
        assert_eq!(
            hex(&digest(b"")),
            "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        );
        assert_eq!(
            hex(&digest(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(
            hex(&digest(
                b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            )),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        );
        assert_eq!(
            hex(&digest(
                b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
            )),
            "a49b2446a02c645bf419f995b67091253a04a259"
        );
        assert_eq!(
            hex(&digest(&vec![b'a'; 1_000_000])),
            "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
        );
    }

    #[test]
    fn every_padding_length() {
        // 55, 56 and 64 bytes straddle the one- and two-block paddings
        // (values from Python's hashlib).
        assert_eq!(
            hex(&digest(&[b'a'; 55])),
            "c1c8bbdc22796e28c0e15163d20899b65621d65a"
        );
        assert_eq!(
            hex(&digest(&[b'a'; 56])),
            "c2db330f6083854c99d4b5bfb6e8f29f201be699"
        );
        assert_eq!(
            hex(&digest(&[b'a'; 64])),
            "0098ba824b5c16427bd7a1122a5a442a25ec644d"
        );
    }
}
