//! config.json read as Swift's `JSONDecoder` reads it (HK-412, HK-413),
//! which is not how `JSONSerialization` reads a harness line
//! (`super::read`). JSONDecoder works in two steps, and a file only fails
//! as a whole when the first one does:
//!
//! 1. A scan of the structure. The text is UTF-8 (one byte order mark
//!    skipped) or UTF-16/UTF-32, detected from a byte order mark or the
//!    zero bytes and transcoded first (a lone surrogate fails the file, an
//!    odd trailing byte is ignored); space, tab, LF and CR may stand
//!    between tokens; at most 512 containers may be open; one trailing
//!    comma is accepted. Strings and numbers are only delimited, keys
//!    included: a number is a run of
//!    `[0-9.eE+-]` that starts with `-` or a digit, a string runs to the
//!    next unescaped quote (a backslash skips one byte, `\u` four more,
//!    whatever they are), and literals are spelled exactly.
//! 2. A conversion when a field reads a value ([`Decoded::as_string`] and
//!    friends), which can fail that one field: a malformed number, a bad
//!    escape, a raw control character or invalid UTF-8 in a string. An
//!    object's keys are converted all at once when it is read as a keyed
//!    container ([`Decoded::keyed`]), and one bad key fails that read: for
//!    the root that is the whole file, for a nested object only the field
//!    that reads it. An unread value is never checked.
//!
//! Of two equal keys the first wins. Everything here was measured with
//! Swift 5.9.2 on macOS 27.2 (`Tests/Fixtures/config/round-trip.json` and
//! the unit tests below pin it). The scan keeps its own stack and dropping
//! a value is iterative, so a 512-deep file never uses the call stack.

use std::borrow::Cow;
use std::collections::BTreeMap;

use serde_json::{Map, Number, Value};

/// One JSON value as JSONDecoder scanned it: structure checked, scalars kept
/// raw until a field converts them.
#[derive(Debug, PartialEq)]
pub(crate) enum Decoded {
    Null,
    Bool(bool),
    /// The raw token, its grammar not yet checked.
    Number(Box<str>),
    /// The raw bytes between the quotes, escapes not yet processed.
    String(Box<[u8]>),
    Array(Vec<Decoded>),
    /// Keys raw, as their strings' bytes, until [`Decoded::keyed`] reads
    /// them; equal keys are all kept.
    Object(Vec<(Box<[u8]>, Decoded)>),
}

/// At most this many arrays and objects may be open at once.
pub(crate) const MAX_OPEN_CONTAINERS: usize = 512;

/// 2^53: below it a double holds every integer, so JSONDecoder converts a
/// non-integer literal to `Int` through the double.
const TWO_TO_53: f64 = 9_007_199_254_740_992.0;

/// 2^63 as a double.
const TWO_TO_63: f64 = 9_223_372_036_854_775_808.0;

/// The document JSONDecoder would scan from `bytes`, or `None` where it
/// throws before any field is read.
pub(crate) fn read_document(bytes: &[u8]) -> Option<Decoded> {
    let text = transcode(bytes)?;
    let mut scanner = Scanner {
        bytes: &text,
        at: 0,
    };
    scanner.skip_whitespace();
    let root = scanner.scan()?;
    scanner.skip_whitespace();
    (scanner.at == text.len()).then_some(root)
}

/// The text as UTF-8 bytes, after Foundation's encoding detection: a UTF-8
/// byte order mark is skipped; `00 00 FE FF` is UTF-32BE and `FF FE` /
/// `FE FF` UTF-16 (so a UTF-32LE mark, `FF FE 00 00`, reads as UTF-16LE
/// starting with U+0000, which then fails the scan, as measured); without
/// a mark the zero bytes among the first four decide. `None` when UTF-16
/// or UTF-32 text does not transcode.
fn transcode(bytes: &[u8]) -> Option<Cow<'_, [u8]>> {
    if bytes.len() >= 4 {
        if let Some(rest) = bytes.strip_prefix(b"\xEF\xBB\xBF") {
            return Some(Cow::Borrowed(rest));
        }
        if let Some(rest) = bytes.strip_prefix(b"\x00\x00\xFE\xFF") {
            return utf32(rest, true);
        }
        if let Some(rest) = bytes.strip_prefix(b"\xFF\xFE") {
            return utf16(rest, false);
        }
        if let Some(rest) = bytes.strip_prefix(b"\xFE\xFF") {
            return utf16(rest, true);
        }
        return match (bytes[0], bytes[1], bytes[2], bytes[3]) {
            (0, 0, 0, _) => utf32(bytes, true),
            (_, 0, 0, 0) => utf32(bytes, false),
            (0, _, 0, _) => utf16(bytes, true),
            (_, 0, _, 0) => utf16(bytes, false),
            _ => Some(Cow::Borrowed(bytes)),
        };
    }
    match bytes {
        [0, _, ..] => utf16(bytes, true),
        [_, 0, ..] => utf16(bytes, false),
        _ => Some(Cow::Borrowed(bytes)),
    }
}

/// UTF-16 to UTF-8; an odd trailing byte is ignored (measured).
fn utf16(bytes: &[u8], big_endian: bool) -> Option<Cow<'static, [u8]>> {
    let units = bytes.as_chunks::<2>().0.iter().map(|&pair| {
        if big_endian {
            u16::from_be_bytes(pair)
        } else {
            u16::from_le_bytes(pair)
        }
    });
    let text: Result<String, _> = char::decode_utf16(units).collect();
    text.ok().map(|text| Cow::Owned(text.into_bytes()))
}

/// UTF-32 to UTF-8; trailing bytes short of a unit are ignored (measured).
fn utf32(bytes: &[u8], big_endian: bool) -> Option<Cow<'static, [u8]>> {
    let mut text = String::with_capacity(bytes.len() / 4);
    for &unit in bytes.as_chunks::<4>().0 {
        let scalar = if big_endian {
            u32::from_be_bytes(unit)
        } else {
            u32::from_le_bytes(unit)
        };
        text.push(char::from_u32(scalar)?);
    }
    Some(Cow::Owned(text.into_bytes()))
}

/// An open container while scanning.
enum Open {
    Array(Vec<Decoded>),
    /// The members so far and the key whose value is being scanned.
    Object(Vec<(Box<[u8]>, Decoded)>, Box<[u8]>),
}

struct Scanner<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Scanner<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    /// One whole value from here, with an explicit stack of open
    /// containers.
    fn scan(&mut self) -> Option<Decoded> {
        let mut open: Vec<Open> = Vec::new();
        loop {
            // A value begins here.
            let mut value = match self.peek()? {
                byte @ (b'{' | b'[') => {
                    if open.len() >= MAX_OPEN_CONTAINERS {
                        return None;
                    }
                    self.at += 1;
                    self.skip_whitespace();
                    if byte == b'{' {
                        if self.eat(b'}') {
                            Decoded::Object(Vec::new())
                        } else {
                            let key = self.key()?;
                            open.push(Open::Object(Vec::new(), key));
                            continue;
                        }
                    } else if self.eat(b']') {
                        Decoded::Array(Vec::new())
                    } else {
                        open.push(Open::Array(Vec::new()));
                        continue;
                    }
                }
                b'"' => Decoded::String(self.raw_string()?.into()),
                b't' => self.literal(b"true", Decoded::Bool(true))?,
                b'f' => self.literal(b"false", Decoded::Bool(false))?,
                b'n' => self.literal(b"null", Decoded::Null)?,
                b'-' | b'0'..=b'9' => Decoded::Number(self.number_token()),
                _ => return None,
            };
            // The value is complete: hand it to its container, closing every
            // container it completes.
            loop {
                let Some(parent) = open.last_mut() else {
                    return Some(value);
                };
                self.skip_whitespace();
                match parent {
                    Open::Array(items) => {
                        items.push(value);
                        if self.eat(b',') {
                            self.skip_whitespace();
                            if !self.eat(b']') {
                                break;
                            }
                        } else if !self.eat(b']') {
                            return None;
                        }
                    }
                    Open::Object(members, key) => {
                        members.push((std::mem::take(key), value));
                        if self.eat(b',') {
                            self.skip_whitespace();
                            if !self.eat(b'}') {
                                *key = self.key()?;
                                break;
                            }
                        } else if !self.eat(b'}') {
                            return None;
                        }
                    }
                }
                value = match open.pop()? {
                    Open::Array(items) => Decoded::Array(items),
                    Open::Object(members, _) => Decoded::Object(members),
                };
            }
            self.skip_whitespace();
        }
    }

    /// A member's key (raw, like any string), then its colon and the
    /// whitespace before its value.
    fn key(&mut self) -> Option<Box<[u8]>> {
        if self.peek() != Some(b'"') {
            return None;
        }
        let key: Box<[u8]> = self.raw_string()?.into();
        self.skip_whitespace();
        if !self.eat(b':') {
            return None;
        }
        self.skip_whitespace();
        Some(key)
    }

    /// The bytes between a string's quotes, from its opening quote. A
    /// backslash skips the byte after it, and `\u` the four after that too,
    /// whatever they are; nothing else is checked yet.
    fn raw_string(&mut self) -> Option<&[u8]> {
        self.at += 1;
        let start = self.at;
        loop {
            match self.peek()? {
                b'"' => {
                    let raw = &self.bytes[start..self.at];
                    self.at += 1;
                    return Some(raw);
                }
                b'\\' => {
                    let escape = *self.bytes.get(self.at + 1)?;
                    self.at += if escape == b'u' { 6 } else { 2 };
                }
                _ => self.at += 1,
            }
        }
    }

    fn literal(&mut self, word: &[u8], value: Decoded) -> Option<Decoded> {
        if self.bytes[self.at..].starts_with(word) {
            self.at += word.len();
            Some(value)
        } else {
            None
        }
    }

    /// The run of number characters from here; its grammar is checked only
    /// when a field converts it.
    fn number_token(&mut self) -> Box<str> {
        let start = self.at;
        while matches!(
            self.peek(),
            Some(b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
        ) {
            self.at += 1;
        }
        // Only ASCII was taken, so this is always text.
        String::from_utf8_lossy(&self.bytes[start..self.at]).into()
    }
}

/// A string's raw bytes as Swift's `String`: valid UTF-8, no raw byte
/// below U+0020, the escapes `\" \\ \/ \b \f \n \r \t \uXXXX` (hex in
/// either case) with surrogates paired, `\u0000` allowed and a leading
/// U+FEFF kept. `None` for anything else.
fn convert_string(raw: &[u8]) -> Option<String> {
    let mut out = String::with_capacity(raw.len());
    let mut at = 0;
    while at < raw.len() {
        let run_start = at;
        while at < raw.len() && raw[at] != b'\\' {
            if raw[at] < 0x20 {
                return None;
            }
            at += 1;
        }
        out.push_str(std::str::from_utf8(&raw[run_start..at]).ok()?);
        if at == raw.len() {
            break;
        }
        // A backslash.
        let escape = *raw.get(at + 1)?;
        at += 2;
        out.push(match escape {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{8}',
            b'f' => '\u{c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => {
                let unit = hex4(raw, at)?;
                at += 4;
                match unit {
                    0xD800..=0xDBFF => {
                        if raw.get(at..at + 2) != Some(b"\\u") {
                            return None;
                        }
                        let low = hex4(raw, at + 2)?;
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return None;
                        }
                        at += 6;
                        char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))?
                    }
                    0xDC00..=0xDFFF => return None,
                    _ => char::from_u32(unit)?,
                }
            }
            _ => return None,
        });
    }
    Some(out)
}

fn hex4(raw: &[u8], at: usize) -> Option<u32> {
    let digits = raw.get(at..at + 4)?;
    if !digits.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
}

/// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, the only
/// numbers a field converts.
fn is_valid_number(token: &str) -> bool {
    let bytes = token.as_bytes();
    let mut at = usize::from(bytes.first() == Some(&b'-'));
    let digits = |at: &mut usize| {
        let start = *at;
        while bytes.get(*at).is_some_and(u8::is_ascii_digit) {
            *at += 1;
        }
        *at > start
    };
    match bytes.get(at) {
        Some(b'0') => at += 1,
        Some(b'1'..=b'9') => {
            digits(&mut at);
        }
        _ => return false,
    }
    if bytes.get(at) == Some(&b'.') {
        at += 1;
        if !digits(&mut at) {
            return false;
        }
    }
    if matches!(bytes.get(at), Some(b'e' | b'E')) {
        at += 1;
        if matches!(bytes.get(at), Some(b'+' | b'-')) {
            at += 1;
        }
        if !digits(&mut at) {
            return false;
        }
    }
    at == bytes.len()
}

/// Whether a literal that parsed as zero really is zero, as Foundation
/// checks it (measured, quirk included): four bytes at a time from the
/// start, a digit 1-9 means no and an exponent mark means yes; the last one
/// to three bytes are only searched for a digit 1-9, exponent digits
/// included. So `0.0e5` is zero but `0e5` and `0.000e5` are not, and a
/// field reading them fails.
fn is_true_zero(token: &str) -> bool {
    let (chunks, remainder) = token.as_bytes().as_chunks::<4>();
    for chunk in chunks {
        for &byte in chunk {
            match byte {
                b'1'..=b'9' => return false,
                b'e' | b'E' => return true,
                _ => {}
            }
        }
    }
    !remainder.iter().any(|byte| (b'1'..=b'9').contains(byte))
}

/// A literal with a fraction or an exponent as JSONDecoder converts it to
/// `Int` when its double is at least 2^53 in magnitude: through `Decimal`,
/// which keeps as many digits as fit in 128 bits (later digits are
/// dropped), drops trailing zeros, needs what is left to fit in 64 bits,
/// and is then cut toward zero; the magnitude must stay below 2^63 (so
/// Int.min itself fails). Measured, including the cut: 12345678901234567.9
/// reads as 12345678901234567.
fn decimal_to_int(token: &str) -> Option<i64> {
    let (negative, unsigned) = match token.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, token),
    };
    let (mantissa, exponent) = match unsigned.find(['e', 'E']) {
        Some(at) => (&unsigned[..at], unsigned[at + 1..].parse::<i64>().ok()?),
        None => (unsigned, 0),
    };
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let mut scale = exponent.checked_sub(i64::try_from(fraction.len()).ok()?)?;
    let mut value: u128 = 0;
    let mut full = false;
    for digit in whole.bytes().chain(fraction.bytes()) {
        let next = value
            .checked_mul(10)
            .and_then(|v| v.checked_add(u128::from(digit - b'0')));
        match next {
            Some(next) if !full => value = next,
            // No room for this digit: it is dropped, and so is every digit
            // after it.
            _ => {
                full = true;
                scale = scale.checked_add(1)?;
            }
        }
    }
    if value == 0 {
        return Some(0);
    }
    while value.is_multiple_of(10) {
        value /= 10;
        scale += 1;
    }
    if value > u128::from(u64::MAX) {
        return None;
    }
    let magnitude = if scale >= 0 {
        let factor = 10u128.checked_pow(u32::try_from(scale).ok()?)?;
        value.checked_mul(factor)?
    } else {
        match 10u128.checked_pow(u32::try_from(-scale).ok()?) {
            Some(divisor) => value / divisor,
            None => 0,
        }
    };
    let magnitude = i64::try_from(magnitude).ok()?;
    Some(if negative { -magnitude } else { magnitude })
}

/// An object read as a keyed container: every key converted.
pub(crate) struct Keyed<'a> {
    members: Vec<(String, &'a Decoded)>,
}

impl<'a> Keyed<'a> {
    /// The first member named `key`.
    pub(crate) fn get(&self, key: &str) -> Option<&'a Decoded> {
        self.members
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| *value)
    }

    /// The members in order, the first of equal keys only.
    fn first_of_each(&self) -> Vec<(&str, &'a Decoded)> {
        let mut seen = std::collections::HashSet::new();
        self.members
            .iter()
            .filter(|(key, _)| seen.insert(key.as_str()))
            .map(|(key, value)| (key.as_str(), *value))
            .collect()
    }
}

impl Decoded {
    /// The object read as a keyed container, its keys converted with the
    /// string rules; `None` for anything but an object, or when one key
    /// does not convert.
    pub(crate) fn keyed(&self) -> Option<Keyed<'_>> {
        let Decoded::Object(members) = self else {
            return None;
        };
        let members = members
            .iter()
            .map(|(key, value)| Some((convert_string(key)?, value)))
            .collect::<Option<Vec<_>>>()?;
        Some(Keyed { members })
    }

    /// Swift's `String` decode (see [`convert_string`]).
    pub(crate) fn as_string(&self) -> Option<String> {
        match self {
            Decoded::String(raw) => convert_string(raw),
            _ => None,
        }
    }

    /// Swift's `Bool` decode: `true` and `false` only.
    pub(crate) fn as_bool(&self) -> Option<bool> {
        match self {
            Decoded::Bool(flag) => Some(*flag),
            _ => None,
        }
    }

    /// Swift's `Int` decode (64-bit). An integer literal must fit exactly.
    /// Otherwise the literal's double decides while it is below 2^53 in
    /// magnitude (it must be integral: `1.0`, `1e2` and even `1e-400`, whose
    /// double is 0, read; `1.5` does not), and from there to 2^63 the
    /// decimal digits do ([`decimal_to_int`]).
    pub(crate) fn as_int(&self) -> Option<i64> {
        let Decoded::Number(token) = self else {
            return None;
        };
        if !is_valid_number(token) {
            return None;
        }
        if !token.contains(['.', 'e', 'E']) {
            // Too large for Int: the slower paths below fail it too.
            return token.parse().ok();
        }
        let double: f64 = token.parse().ok()?;
        if !double.is_finite() {
            return None;
        }
        if double.abs() < TWO_TO_53 {
            // Exact: integral and below 2^53.
            #[allow(clippy::cast_possible_truncation)]
            return (double.fract() == 0.0).then_some(double as i64);
        }
        if !(-TWO_TO_63..TWO_TO_63).contains(&double) {
            return None;
        }
        decimal_to_int(token)
    }

    /// Swift's `Double` decode: the nearest double; an overflow fails, and
    /// so does a zero that [`is_true_zero`] rejects (an underflow).
    pub(crate) fn as_double(&self) -> Option<f64> {
        let Decoded::Number(token) = self else {
            return None;
        };
        if !is_valid_number(token) {
            return None;
        }
        let double: f64 = token.parse().ok()?;
        (double.is_finite() && (double != 0.0 || is_true_zero(token))).then_some(double)
    }

    /// Swift's `Float` decode: the nearest Float to the decimal (rounded
    /// once, not through a double), with the same overflow and zero rules.
    pub(crate) fn as_float(&self) -> Option<f32> {
        let Decoded::Number(token) = self else {
            return None;
        };
        if !is_valid_number(token) {
            return None;
        }
        let float: f32 = token.parse().ok()?;
        (float.is_finite() && (float != 0.0 || is_true_zero(token))).then_some(float)
    }

    /// Swift's `[String]` decode: every element a string, or nothing.
    pub(crate) fn as_string_array(&self) -> Option<Vec<String>> {
        match self {
            Decoded::Array(items) => items.iter().map(Decoded::as_string).collect(),
            _ => None,
        }
    }

    /// Swift's `[String: String]` decode: every key converted, the first
    /// of equal keys, then every value a string, or nothing.
    pub(crate) fn as_string_map(&self) -> Option<BTreeMap<String, String>> {
        self.keyed()?
            .first_of_each()
            .into_iter()
            .map(|(key, value)| Some((key.to_owned(), value.as_string()?)))
            .collect()
    }

    /// The value as the app's `JSONValue` read it for the mapping subtree:
    /// null, then Bool, Int64, Double, String, array and object in turn,
    /// and null for a value none of them can hold (a malformed number or
    /// string, an object with a key that does not convert). Objects keep
    /// the first of equal keys. Iterative, so the
    /// deepest file never uses the call stack here.
    pub(crate) fn to_mapping_value(&self) -> Value {
        enum Step<'a> {
            Convert(&'a Decoded),
            CloseArray(usize),
            CloseObject(Vec<String>),
        }
        let mut steps = vec![Step::Convert(self)];
        let mut done: Vec<Value> = Vec::new();
        while let Some(step) = steps.pop() {
            match step {
                Step::Convert(value) => match value {
                    Decoded::Null => done.push(Value::Null),
                    Decoded::Bool(flag) => done.push(Value::Bool(*flag)),
                    Decoded::Number(_) => done.push(match (value.as_int(), value.as_double()) {
                        (Some(int), _) => Value::from(int),
                        (None, Some(double)) => {
                            Number::from_f64(double).map_or(Value::Null, Value::Number)
                        }
                        (None, None) => Value::Null,
                    }),
                    Decoded::String(_) => {
                        done.push(value.as_string().map_or(Value::Null, Value::String));
                    }
                    Decoded::Array(items) => {
                        steps.push(Step::CloseArray(items.len()));
                        steps.extend(items.iter().rev().map(Step::Convert));
                    }
                    Decoded::Object(_) => match value.keyed() {
                        Some(keyed) => {
                            let kept = keyed.first_of_each();
                            steps.push(Step::CloseObject(
                                kept.iter().map(|(key, _)| (*key).to_owned()).collect(),
                            ));
                            steps.extend(kept.iter().rev().map(|(_, value)| Step::Convert(value)));
                        }
                        None => done.push(Value::Null),
                    },
                },
                Step::CloseArray(count) => {
                    let items = done.split_off(done.len().saturating_sub(count));
                    done.push(Value::Array(items));
                }
                Step::CloseObject(keys) => {
                    let values = done.split_off(done.len().saturating_sub(keys.len()));
                    let map: Map<String, Value> = keys.into_iter().zip(values).collect();
                    done.push(Value::Object(map));
                }
            }
        }
        done.pop().unwrap_or(Value::Null)
    }

    /// Moves this value's children onto `into`, leaving it shallow.
    fn take_children(&mut self, into: &mut Vec<Decoded>) {
        match self {
            Decoded::Array(items) => into.append(items),
            Decoded::Object(members) => into.extend(members.drain(..).map(|(_, value)| value)),
            _ => {}
        }
    }
}

impl Drop for Decoded {
    /// Iterative, so a deep value never uses the call stack to go away.
    fn drop(&mut self) {
        let mut pending = Vec::new();
        self.take_children(&mut pending);
        while let Some(mut child) = pending.pop() {
            child.take_children(&mut pending);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(json: &str) -> Decoded {
        let mut root = read_document(format!(r#"{{"f":{json}}}"#).as_bytes()).unwrap();
        let Decoded::Object(members) = &mut root else {
            unreachable!()
        };
        members.remove(0).1
    }

    #[test]
    fn the_scan_fails_only_on_structure() {
        for loads in [
            r#"{"o":01}"#,
            r#"{"o":1.2.3,"p":--1,"q":1e5e5,"r":-,"s":1.,"t":1e}"#,
            r#"{"o":"\q"}"#,
            r#"{"o":"\u12zz"}"#,
            "{\"o\":\"a\tb\"}",
            r#"{"a":1,}"#,
            r#"{"a":[1,],"b":2 ,}"#,
            r#"{"a\u0000b":1}"#,
            " \r\n\t{}\n ",
            // Keys are only delimited by the scan.
            r#"{"\udc00":1}"#,
            "{\"a\tb\":1}",
            r#"{"q\x":1}"#,
        ] {
            assert!(read_document(loads.as_bytes()).is_some(), "{loads}");
        }
        for corrupt in [
            r#"{"o":"\u12"}"#,
            r#"{"o":+1}"#,
            r#"{"o":.5}"#,
            r#"{"o":1x}"#,
            r#"{"o":-x}"#,
            r#"{"o":0x10}"#,
            r#"{"o":1"m":2}"#,
            r#"{"o":truex}"#,
            r#"{"o":True}"#,
            r#"{"o":nul}"#,
            r#"{"\u12":1}"#,
            "{,}",
            r#"{"a":[,]}"#,
            r#"{"a":[1,,]}"#,
            r#"{"a":1,,}"#,
            "{}\u{0}",
            "\u{c}{}",
            "",
            "{",
        ] {
            assert!(read_document(corrupt.as_bytes()).is_none(), "{corrupt:?}");
        }
    }

    #[test]
    fn at_most_512_containers_may_be_open() {
        let arrays = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        assert!(read_document(arrays(512).as_bytes()).is_some());
        assert!(read_document(arrays(513).as_bytes()).is_none());
        let in_object = |n: usize| format!(r#"{{"a":{}}}"#, arrays(n));
        assert!(read_document(in_object(511).as_bytes()).is_some());
        assert!(read_document(in_object(512).as_bytes()).is_none());
    }

    #[test]
    fn a_deep_document_does_not_use_the_call_stack() {
        let worker = std::thread::Builder::new()
            .stack_size(128 * 1024)
            .spawn(|| {
                let text = format!(r#"{{"a":{}1{}}}"#, "[".repeat(511), "]".repeat(511));
                let document = read_document(text.as_bytes());
                let value = document.as_ref().map(Decoded::to_mapping_value);
                let read = document.is_some();
                drop(document);
                // The serde value is the mapping layer's; only its existence
                // is checked here, and it is forgotten rather than dropped
                // recursively on this small stack.
                let converted = value.is_some();
                std::mem::forget(value);
                read && converted
            })
            .unwrap();
        assert!(worker.join().unwrap());
    }

    #[test]
    fn encodings_are_detected_like_foundation() {
        let doc = r#"{"m":"é"}"#;
        let utf16 = |be: bool| -> Vec<u8> {
            doc.encode_utf16()
                .flat_map(|u| if be { u.to_be_bytes() } else { u.to_le_bytes() })
                .collect()
        };
        let utf32 = |be: bool| -> Vec<u8> {
            doc.chars()
                .flat_map(|c| {
                    let v = c as u32;
                    if be {
                        v.to_be_bytes()
                    } else {
                        v.to_le_bytes()
                    }
                })
                .collect()
        };
        let read = |bytes: Vec<u8>| {
            let document = read_document(&bytes)?;
            let keyed = document.keyed()?;
            keyed.get("m").and_then(Decoded::as_string)
        };
        let e = Some("é".to_owned());
        assert_eq!(
            read([b"\xEF\xBB\xBF".as_slice(), doc.as_bytes()].concat()),
            e
        );
        assert_eq!(read(utf16(false)), e);
        assert_eq!(read(utf16(true)), e);
        assert_eq!(read([b"\xFF\xFE".to_vec(), utf16(false)].concat()), e);
        assert_eq!(read([b"\xFE\xFF".to_vec(), utf16(true)].concat()), e);
        assert_eq!(read(utf32(false)), e);
        assert_eq!(read(utf32(true)), e);
        assert_eq!(
            read([b"\x00\x00\xFE\xFF".to_vec(), utf32(true)].concat()),
            e
        );
        // FF FE first: a UTF-32LE mark reads as UTF-16LE and U+0000.
        assert_eq!(
            read([b"\xFF\xFE\x00\x00".to_vec(), utf32(false)].concat()),
            None
        );
        // An odd trailing byte is ignored; a lone surrogate fails the file.
        assert_eq!(read([utf16(false), vec![0x7B]].concat()), e);
        assert_eq!(read([utf32(true), vec![0, 0x20]].concat()), e);
        let mut lone = utf16(false);
        lone.splice(12..12, [0x00, 0xD8]);
        assert!(read_document(&lone).is_none());
        // Two byte order marks, or a UTF-8 mark before UTF-16, fail.
        assert!(read_document(b"\xEF\xBB\xBF\xEF\xBB\xBF{}").is_none());
        assert!(read_document(&[b"\xEF\xBB\xBF".to_vec(), utf16(false)].concat()).is_none());
    }

    #[test]
    fn strings_convert_lazily_and_strictly() {
        let string = |json: &str| field(json).as_string();
        assert_eq!(string(r#""a\/bé😀""#).as_deref(), Some("a/bé😀"));
        assert_eq!(string(r#""a\u0000b""#).as_deref(), Some("a\u{0}b"));
        assert_eq!(string("\"\u{FEFF}x\"").as_deref(), Some("\u{FEFF}x"));
        assert_eq!(string("\"\u{7f}\"").as_deref(), Some("\u{7f}"));
        for fails in [
            r#""\q""#,
            "\"a\tb\"",
            r#""\ud800""#,
            r#""\udc00""#,
            r#""\uD83Dx""#,
            r#""\uD83DA""#,
            r#""\U0041""#,
            r#""\u12zz""#,
            "1",
            "null",
        ] {
            assert_eq!(string(fails), None, "{fails}");
        }
        let raw = |bytes: &[u8]| {
            let mut text = br#"{"f":""#.to_vec();
            text.extend_from_slice(bytes);
            text.extend_from_slice(br#""}"#);
            let document = read_document(&text).unwrap();
            let keyed = document.keyed().unwrap();
            keyed.get("f").unwrap().as_string()
        };
        assert_eq!(raw(b"\xFF"), None);
        assert_eq!(raw(b"\xA9"), None);
        assert_eq!(raw(b"\xC0\xAF"), None);
        assert_eq!(raw(b"\xED\xA0\x80"), None);
        // Keys convert with the same rules when their object is read; one
        // bad key fails that read.
        for bad in [
            &b"{\"\xFF\":1}"[..],
            b"{\"a\tb\":1}",
            br#"{"\q":1}"#,
            br#"{"\udc00":1}"#,
        ] {
            assert!(read_document(bad).unwrap().keyed().is_none());
        }
        assert!(field(r#"{"a":"1","\q":"2"}"#).as_string_map().is_none());
        let keyed = read_document(br#"{"mo\u0064el":1,"\ufeffx":2}"#).unwrap();
        let keyed = keyed.keyed().unwrap();
        assert!(keyed.get("model").is_some() && keyed.get("\u{FEFF}x").is_some());
    }

    #[test]
    fn ints_convert_like_jsondecoder() {
        // Measured with Swift 5.9.2 on macOS 27.2.
        for (json, int) in [
            ("1", Some(1)),
            ("-0", Some(0)),
            ("-0.0", Some(0)),
            ("1.0", Some(1)),
            ("1e2", Some(100)),
            ("1E-0", Some(1)),
            ("100e-2", Some(1)),
            ("1.5e1", Some(15)),
            ("0.5e1", Some(5)),
            ("1e-400", Some(0)),
            ("-1e-400", Some(0)),
            ("0e400", Some(0)),
            ("1.0000000000000001", Some(1)),
            ("4503599627370497.5", Some(4_503_599_627_370_498)),
            ("9007199254740991.7", Some(9_007_199_254_740_991)),
            ("9007199254740993.0", Some(9_007_199_254_740_993)),
            ("12345678901234567.0", Some(12_345_678_901_234_567)),
            ("12345678901234567.9", Some(12_345_678_901_234_567)),
            ("-12345678901234567.9", Some(-12_345_678_901_234_567)),
            ("12345678901234567.999", Some(12_345_678_901_234_567)),
            ("12345678901234567.9999", None),
            ("12345678901234567.0000", Some(12_345_678_901_234_567)),
            ("12345678901234567.999999999999999999999", None),
            ("12345678901234567.0000000000000000000001", None),
            (
                "12345678901234567.00000000000000000000001",
                Some(12_345_678_901_234_567),
            ),
            ("123456789012345678901234567890e-12", None),
            ("18446744073709551615e-2", Some(184_467_440_737_095_516)),
            ("18446744073709551616e-2", None),
            ("184467440737095516150e-3", Some(184_467_440_737_095_516)),
            ("9223372036854775807", Some(i64::MAX)),
            ("-9223372036854775808", Some(i64::MIN)),
            ("9223372036854775808", None),
            ("9223372036854775807.0", None),
            ("9223372036854775806.0", None),
            ("9223372036854774784.0", Some(9_223_372_036_854_774_784)),
            ("-9223372036854775807.0", Some(-i64::MAX)),
            ("-9223372036854775808.0", None),
            ("1e19", None),
            ("1e400", None),
            ("10.000000000000001", None),
            ("5e-1", None),
            ("1e-5", None),
            ("00", None),
            ("-", None),
            ("1.", None),
            ("true", None),
            ("\"1\"", None),
        ] {
            assert_eq!(field(json).as_int(), int, "{json}");
        }
    }

    #[test]
    fn doubles_and_floats_convert_like_jsondecoder() {
        for (json, double) in [
            ("4.9e-324", Some(5e-324)),
            ("1.7976931348623158e308", Some(f64::MAX)),
            ("1.7976931348623159e308", None),
            ("1e-400", None),
            ("2e-324", None),
            ("0e-400", Some(0.0)),
            ("-0", Some(-0.0)),
            ("0.0", Some(0.0)),
            ("0.0e5", Some(0.0)),
            ("0.0000e5", Some(0.0)),
            ("0.00000e5", Some(0.0)),
            ("0.000e-5", Some(0.0)),
            ("0.00e0", Some(0.0)),
            ("-0.000e5", Some(-0.0)),
            ("-0e5", Some(-0.0)),
            ("0e5", None),
            ("0E5", None),
            ("0.00e5", None),
            ("0.000e5", None),
            ("0.000000e5", None),
            ("0.00e+5", None),
            ("-0.00e5", None),
            ("true", None),
        ] {
            assert_eq!(field(json).as_double(), double, "{json}");
        }
        for (json, float) in [
            ("1", Some(1.0)),
            ("0.1", Some(0.1)),
            ("16777217", Some(16_777_216.0)),
            ("1.401298464324817e-45", Some(1e-45)),
            ("7.006492321624085e-46", None),
            ("7.006492321624086e-46", Some(1e-45)),
            ("1e-46", None),
            ("3.4028235677973366e38", Some(f32::MAX)),
            ("3.402823567797337e38", None),
            // Rounded once from the decimal: through a double this would
            // land on a tie and round to 1.0.
            ("1.0000000596046447753906251", Some(1.000_000_1)),
            ("1.000000059604644775390625", Some(1.0)),
            ("0.0e5", Some(0.0)),
            ("0e5", None),
            ("\"0.5\"", None),
        ] {
            assert_eq!(field(json).as_float(), float, "{json}");
        }
    }

    #[test]
    fn collections_are_all_or_nothing() {
        assert_eq!(
            field(r#"["a","b"]"#).as_string_array(),
            Some(vec!["a".to_owned(), "b".to_owned()])
        );
        assert_eq!(field(r#"["a",1]"#).as_string_array(), None);
        assert_eq!(field(r#"["a",null]"#).as_string_array(), None);
        assert_eq!(field(r#"["a","\q"]"#).as_string_array(), None);
        let map = field(r#"{"a":"1","a":2,"b":"x"}"#).as_string_map().unwrap();
        assert_eq!(map.get("a").map(String::as_str), Some("1"));
        assert_eq!(map.len(), 2);
        assert_eq!(field(r#"{"a":2,"a":"1"}"#).as_string_map(), None);
        assert_eq!(field(r#"{"a":null}"#).as_string_map(), None);
    }

    #[test]
    fn the_mapping_view_reads_like_jsonvalue() {
        let value = field(r#"{"a":[1,1.5,"\q",01,true,null,{"k":"v","k":"w"},{"\q":1}],"a":0}"#)
            .to_mapping_value();
        assert_eq!(
            value,
            serde_json::json!({"a": [1, 1.5, null, null, true, null, {"k": "v"}, null]})
        );
    }
}
