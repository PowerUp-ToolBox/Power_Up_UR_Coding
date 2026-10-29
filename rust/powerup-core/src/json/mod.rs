//! One harness stdout line (the claude CLI's stream-json, an ACP agent's
//! JSON-RPC) read as Foundation's `JSONSerialization` reads it (HK-393),
//! and its fields read as Swift reads them through `NSNumber` (HK-394).
//!
//! serde_json reads differently in ways a line can show: it keeps the last
//! of two equal keys where Foundation keeps the first, it refuses a byte
//! order mark and a trailing comma, and it recurses once per nesting level.
//! The stdout reader thread has a 512 KB stack, and a stack overflow is not
//! a panic the bridge can catch, so this reader keeps its own stack and
//! never recurses, and dropping a value is iterative too.
//!
//! Measured on macOS 27.2 (Tests/Fixtures/harness/claude-stream.json pins
//! each rule):
//! - the line must be valid UTF-8, after one optional leading UTF-8 byte
//!   order mark, with one exception: a stray byte 0xA9 inside a string
//!   (where a character should begin) reads as U+FFFD. No other stray byte
//!   is read, and 0xA9 outside a string rejects the line too;
//! - the root is an object or an array, with space, tab, LF and CR around
//!   it and nothing else;
//! - of two equal keys the first wins;
//! - one trailing comma after the last member or element is accepted;
//! - a value (a key included) may begin only while at most 512 containers
//!   are open, so 513 nested empty arrays read but a value inside them
//!   does not;
//! - a number is the RFC 8259 grammar; it reads as the nearest double, a
//!   number that overflows rejects the line and one that underflows reads
//!   as zero;
//! - strings reject raw control characters below U+0020, unknown escapes
//!   and unpaired surrogates; `\u0000` is an ordinary character;
//! - one U+FEFF at the start of a string (a key included), raw or escaped,
//!   is dropped; a second one, or one later in the string, is kept.
//!
//! Recorded differences, none of which a claude CLI line can show (it
//! writes UTF-8 JSON whose numbers have at most 17 significant digits):
//! Foundation also detects UTF-16 and UTF-32 text, which this reader
//! rejects; it reads a number with more than 17 significant digits as an
//! NSDecimalNumber and rejects the line when its exponent leaves Decimal's
//! range, and rejects some exponents of four digits or more; and Swift's
//! bridged dictionary merges keys that are canonically equivalent but
//! spelled differently, which this reader keeps apart. Numbers are read as
//! doubles, so an integer past 2^53 can read differently from Swift's
//! `Int` (HK-403); no agent sends such an id or token count.
//!
//! [`write`] goes the other way for the lines an ACP adapter sends: compact
//! text, members in the order they were built, strings escaped as Swift
//! escapes them, without recursion either (an agent's id is echoed back as
//! read, however deep).
//!
//! The hooks merge (slice 2.5) reads `~/.claude/settings.json` with the same
//! reader, which is why each number also keeps its literal:
//! [`write_verbatim`] hands the merged file back to Foundation with every
//! number spelled as the person's file spelled it (HK-417). There the
//! differences above mean that a UTF-16 or UTF-32 settings.json is refused
//! as invalid JSON instead of read, and that a file holding a number
//! Decimal cannot hold reads here; the macOS writer still refuses to write
//! it back.
//!
//! config.json is read by the app's other Foundation reader, `JSONDecoder`,
//! whose tolerances differ; [`decoder`] reads it that way, and [`encoder`]
//! writes what `JSONEncoder` writes.

pub(crate) mod decoder;
pub(crate) mod encoder;

use crate::{wire, CoreError};

/// A JSON value. Objects keep every member in order; [`JsonValue::get`]
/// answers the first, as Foundation does.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum JsonValue {
    Null,
    Bool(bool),
    Number(JsonNumber),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

/// A number as read: the nearest double, and the literal exactly as the
/// text spelled it, so [`write_verbatim`] can hand another tool's number
/// back to Foundation unchanged (a double would lose `0.1` against
/// `0.10000000000000001`, or the digits of a 30-digit integer). Two numbers
/// are equal when their values are.
#[derive(Debug, Clone)]
pub(crate) struct JsonNumber {
    pub(crate) value: f64,
    pub(crate) literal: Box<str>,
}

impl PartialEq for JsonNumber {
    fn eq(&self, other: &Self) -> bool {
        self.value == other.value
    }
}

impl JsonNumber {
    /// A number the core builds (an id, a code), spelled as an integer.
    /// Our ids and codes are far below 2^53, so the double holds them
    /// exactly.
    #[allow(clippy::cast_precision_loss)]
    pub(crate) fn from_i64(value: i64) -> Self {
        JsonNumber {
            value: value as f64,
            literal: value.to_string().into_boxed_str(),
        }
    }
}

/// A value may begin only while at most this many containers are open.
pub(crate) const MAX_OPEN_CONTAINERS: usize = 512;

const BYTE_ORDER_MARK: &[u8] = b"\xEF\xBB\xBF";

impl JsonValue {
    /// The first member named `key` of an object; `None` for anything else.
    pub(crate) fn get(&self, key: &str) -> Option<&JsonValue> {
        self.as_object()?
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }

    /// Swift's `as? String`: strings only.
    pub(crate) fn as_str(&self) -> Option<&str> {
        match self {
            JsonValue::String(text) => Some(text),
            _ => None,
        }
    }

    /// Swift's `as? Bool` on an NSNumber: a bool, or a number that is
    /// exactly 0 or 1. Any other number reads as missing.
    pub(crate) fn as_swift_bool(&self) -> Option<bool> {
        match self {
            JsonValue::Bool(flag) => Some(*flag),
            JsonValue::Number(number) if number.value == 0.0 => Some(false),
            JsonValue::Number(number) if number.value == 1.0 => Some(true),
            _ => None,
        }
    }

    /// Swift's `(as? NSNumber)?.doubleValue`: a number, or a bool as 1 or 0.
    pub(crate) fn as_swift_number(&self) -> Option<f64> {
        match self {
            JsonValue::Number(number) => Some(number.value),
            JsonValue::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
            _ => None,
        }
    }

    pub(crate) fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            JsonValue::Array(items) => Some(items),
            _ => None,
        }
    }

    pub(crate) fn as_object(&self) -> Option<&[(String, JsonValue)]> {
        match self {
            JsonValue::Object(members) => Some(members),
            _ => None,
        }
    }

    /// Swift's `as? Int` on a JSONSerialization value (measured with Swift
    /// 5.9.2): a bool reads as 1 or 0, a number only when it is integral and
    /// inside `Int`'s range. 1.0 and 1e2 read; 1.5, 1e19, strings and null
    /// do not.
    pub(crate) fn as_swift_int(&self) -> Option<i64> {
        match self {
            JsonValue::Bool(flag) => Some(i64::from(*flag)),
            JsonValue::Number(JsonNumber { value, .. })
                if value.fract() == 0.0 && (-TWO_TO_63..TWO_TO_63).contains(value) =>
            {
                // Exact: integral and inside i64's range.
                #[allow(clippy::cast_possible_truncation)]
                Some(*value as i64)
            }
            _ => None,
        }
    }

    /// Swift's `(as? NSNumber)?.intValue`: a number truncated toward zero
    /// and saturated at `Int`'s bounds, a bool as 1 or 0; anything else
    /// `None`.
    pub(crate) fn as_swift_int_value(&self) -> Option<i64> {
        match self {
            JsonValue::Bool(flag) => Some(i64::from(*flag)),
            // `as` truncates toward zero and saturates, which is what
            // NSNumber's intValue does with a double.
            #[allow(clippy::cast_possible_truncation)]
            JsonValue::Number(number) => Some(number.value as i64),
            _ => None,
        }
    }

    /// Swift's `as? [[String: Any]]`: the elements of an array when every
    /// one is an object. One element of another kind fails the whole cast
    /// (measured: `[{"optionId":"a"},5]` casts to nil).
    pub(crate) fn as_object_array(&self) -> Option<Vec<&JsonValue>> {
        let items = self.as_array()?;
        items
            .iter()
            .all(|item| item.as_object().is_some())
            .then(|| items.iter().collect())
    }

    /// Moves this value's children onto `into`, leaving it shallow.
    fn take_children(&mut self, into: &mut Vec<JsonValue>) {
        match self {
            JsonValue::Array(items) => into.append(items),
            JsonValue::Object(members) => into.extend(members.drain(..).map(|(_, value)| value)),
            _ => {}
        }
    }
}

impl Drop for JsonValue {
    /// Iterative, so a deep value never uses the call stack to go away.
    fn drop(&mut self) {
        let mut pending = Vec::new();
        self.take_children(&mut pending);
        while let Some(mut child) = pending.pop() {
            child.take_children(&mut pending);
        }
    }
}

/// 2^63 as a double: the first integer past `Int`'s range.
const TWO_TO_63: f64 = 9_223_372_036_854_775_808.0;

/// 2^53: integers below it are exact in a double, so they are written as
/// integers.
const TWO_TO_53: f64 = 9_007_199_254_740_992.0;

/// One step of [`write`]'s explicit stack.
enum Write<'a> {
    Value(&'a JsonValue),
    Key(&'a str),
    Text(&'static str),
}

/// Compact JSON text of `value`: members in order, strings escaped as Swift
/// escapes them (`wire::to_swift_json`, so `/` is `\/`), an integral number
/// below 2^53 in magnitude as an integer and any other number as serde
/// writes a double (`-1.5`, `1e+20`, as Swift writes them). Of two members
/// with the same key only the first is written, as a Swift dictionary read
/// from the line would hold it. Iterative: an explicit stack, never
/// recursion.
pub(crate) fn write(value: &JsonValue) -> Result<String, CoreError> {
    let mut out = String::new();
    let mut stack = vec![Write::Value(value)];
    while let Some(step) = stack.pop() {
        match step {
            Write::Text(text) => out.push_str(text),
            Write::Key(key) => {
                out.push_str(&wire::to_swift_json(key)?);
                out.push(':');
            }
            Write::Value(value) => match value {
                JsonValue::Null => out.push_str("null"),
                JsonValue::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
                JsonValue::Number(JsonNumber { value: number, .. }) => {
                    if number.fract() == 0.0 && number.abs() < TWO_TO_53 {
                        // Exact: integral and below 2^53.
                        #[allow(clippy::cast_possible_truncation)]
                        out.push_str(&(*number as i64).to_string());
                    } else {
                        out.push_str(&wire::to_swift_json(number)?);
                    }
                }
                JsonValue::String(text) => out.push_str(&wire::to_swift_json(text.as_str())?),
                JsonValue::Array(items) => {
                    out.push('[');
                    stack.push(Write::Text("]"));
                    for (index, item) in items.iter().enumerate().rev() {
                        stack.push(Write::Value(item));
                        if index > 0 {
                            stack.push(Write::Text(","));
                        }
                    }
                }
                JsonValue::Object(members) => {
                    out.push('{');
                    stack.push(Write::Text("}"));
                    // One pass with a set of keys seen, so an object of many
                    // members (an agent's id is echoed as read) stays linear.
                    let mut seen = std::collections::HashSet::new();
                    let kept: Vec<&(String, JsonValue)> = members
                        .iter()
                        .filter(|(key, _)| seen.insert(key.as_str()))
                        .collect();
                    for (index, (key, item)) in kept.into_iter().enumerate().rev() {
                        stack.push(Write::Value(item));
                        stack.push(Write::Key(key));
                        if index > 0 {
                            stack.push(Write::Text(","));
                        }
                    }
                }
            },
        }
    }
    Ok(out)
}

/// Compact JSON text of a value [`read`] returned, for Foundation's
/// `JSONSerialization` to read back as the value it read in the first
/// place: numbers keep their literal, so Foundation reads the same NSNumber
/// or NSDecimalNumber it would have read from the original file; of two
/// members with the same key only the first is written (the one Foundation
/// kept); and a string or key that starts with U+FEFF gets one more,
/// because Foundation drops one leading U+FEFF of every string it reads.
/// Strings are otherwise escaped as `write` escapes them. Iterative, like
/// [`write`].
pub(crate) fn write_verbatim(value: &JsonValue) -> Result<String, CoreError> {
    let mut out = String::new();
    let mut stack = vec![Write::Value(value)];
    while let Some(step) = stack.pop() {
        match step {
            Write::Text(text) => out.push_str(text),
            Write::Key(key) => {
                push_verbatim_string(&mut out, key)?;
                out.push(':');
            }
            Write::Value(value) => match value {
                JsonValue::Null => out.push_str("null"),
                JsonValue::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
                JsonValue::Number(number) => out.push_str(&number.literal),
                JsonValue::String(text) => push_verbatim_string(&mut out, text)?,
                JsonValue::Array(items) => {
                    out.push('[');
                    stack.push(Write::Text("]"));
                    for (index, item) in items.iter().enumerate().rev() {
                        stack.push(Write::Value(item));
                        if index > 0 {
                            stack.push(Write::Text(","));
                        }
                    }
                }
                JsonValue::Object(members) => {
                    out.push('{');
                    stack.push(Write::Text("}"));
                    let mut seen = std::collections::HashSet::new();
                    let kept: Vec<&(String, JsonValue)> = members
                        .iter()
                        .filter(|(key, _)| seen.insert(key.as_str()))
                        .collect();
                    for (index, (key, item)) in kept.into_iter().enumerate().rev() {
                        stack.push(Write::Value(item));
                        stack.push(Write::Key(key));
                        if index > 0 {
                            stack.push(Write::Text(","));
                        }
                    }
                }
            },
        }
    }
    Ok(out)
}

fn push_verbatim_string(out: &mut String, text: &str) -> Result<(), CoreError> {
    if text.starts_with('\u{FEFF}') {
        let doubled = format!("\u{FEFF}{text}");
        out.push_str(&wire::to_swift_json(doubled.as_str())?);
    } else {
        out.push_str(&wire::to_swift_json(text)?);
    }
    Ok(())
}

/// An open container while reading.
enum Open {
    Array(Vec<JsonValue>),
    /// The members so far and the key whose value is being read.
    Object(Vec<(String, JsonValue)>, Option<String>),
}

/// `JSONSerialization.jsonObject(with:)` for one line: the value, or `None`
/// where Foundation would throw.
pub(crate) fn read(bytes: &[u8]) -> Option<JsonValue> {
    let bytes = bytes.strip_prefix(BYTE_ORDER_MARK).unwrap_or(bytes);
    let text = decode(bytes)?;
    let mut reader = Reader { text: &text, at: 0 };
    reader.skip_whitespace();
    if !matches!(reader.peek(), Some(b'{' | b'[')) {
        return None;
    }
    let root = reader.read_root()?;
    reader.skip_whitespace();
    (reader.at == text.len()).then_some(root)
}

/// The byte a measured Foundation reads as U+FFFD inside a string where a
/// character should begin, instead of rejecting the line. Every other
/// stray byte from 0x80 to 0xFF, and every invalid two-byte sequence, is
/// rejected (all measured on macOS 27.2).
const READ_AS_REPLACEMENT: u8 = 0xA9;

/// The line as text: valid UTF-8 as it is, and otherwise the same text
/// with each stray 0xA9 inside a string replaced by U+FFFD, or `None` when
/// any other invalid byte remains. A string is tracked by its quotes and
/// backslash escapes, as the reader will find it; a stray byte right after
/// a backslash is not replaced, since no escape could read it anyway.
fn decode(bytes: &[u8]) -> Option<std::borrow::Cow<'_, str>> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(std::borrow::Cow::Borrowed(text));
    }
    let mut out = String::with_capacity(bytes.len() + 2);
    let mut rest = bytes;
    let mut in_string = false;
    let mut escaped = false;
    loop {
        let (valid, stray) = match std::str::from_utf8(rest) {
            Ok(text) => (text, None),
            Err(error) => {
                let (head, tail) = rest.split_at(error.valid_up_to());
                (std::str::from_utf8(head).ok()?, Some(tail))
            }
        };
        for byte in valid.bytes() {
            if !in_string {
                in_string = byte == b'"';
            } else if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
        }
        out.push_str(valid);
        let Some(stray) = stray else {
            return Some(std::borrow::Cow::Owned(out));
        };
        match stray.split_first() {
            Some((&READ_AS_REPLACEMENT, after)) if in_string && !escaped => {
                out.push('\u{FFFD}');
                rest = after;
            }
            _ => return None,
        }
    }
}

struct Reader<'a> {
    text: &'a str,
    at: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.at).copied()
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

    /// The whole value from the root's opening bracket, with an explicit
    /// stack of open containers.
    fn read_root(&mut self) -> Option<JsonValue> {
        let mut open: Vec<Open> = Vec::new();
        loop {
            // A value begins here.
            self.skip_whitespace();
            if open.len() > MAX_OPEN_CONTAINERS {
                return None;
            }
            let mut value = match self.peek()? {
                b'{' => {
                    self.at += 1;
                    self.skip_whitespace();
                    if self.eat(b'}') {
                        JsonValue::Object(Vec::new())
                    } else {
                        let key = self.read_key(open.len() + 1)?;
                        open.push(Open::Object(Vec::new(), Some(key)));
                        continue;
                    }
                }
                b'[' => {
                    self.at += 1;
                    self.skip_whitespace();
                    if self.eat(b']') {
                        JsonValue::Array(Vec::new())
                    } else {
                        open.push(Open::Array(Vec::new()));
                        continue;
                    }
                }
                b'"' => JsonValue::String(self.read_string()?),
                b't' => self.read_literal("true", JsonValue::Bool(true))?,
                b'f' => self.read_literal("false", JsonValue::Bool(false))?,
                b'n' => self.read_literal("null", JsonValue::Null)?,
                b'-' | b'0'..=b'9' => JsonValue::Number(self.read_number()?),
                _ => return None,
            };
            // The value is complete: hand it to its container, closing every
            // container it completes.
            loop {
                let depth = open.len();
                let Some(parent) = open.last_mut() else {
                    return Some(value);
                };
                match parent {
                    Open::Array(items) => {
                        items.push(value);
                        self.skip_whitespace();
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
                        let name = key.take()?;
                        members.push((name, value));
                        self.skip_whitespace();
                        if self.eat(b',') {
                            self.skip_whitespace();
                            if !self.eat(b'}') {
                                *key = Some(self.read_key(depth)?);
                                break;
                            }
                        } else if !self.eat(b'}') {
                            return None;
                        }
                    }
                }
                value = match open.pop()? {
                    Open::Array(items) => JsonValue::Array(items),
                    Open::Object(members, _) => JsonValue::Object(members),
                };
            }
        }
    }

    /// A member's key and its colon; `open` containers are open around it.
    fn read_key(&mut self, open: usize) -> Option<String> {
        if open > MAX_OPEN_CONTAINERS || self.peek() != Some(b'"') {
            return None;
        }
        let key = self.read_string()?;
        self.skip_whitespace();
        self.eat(b':').then_some(key)
    }

    fn read_literal(&mut self, word: &str, value: JsonValue) -> Option<JsonValue> {
        if self.text[self.at..].starts_with(word) {
            self.at += word.len();
            Some(value)
        } else {
            None
        }
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, read as the
    /// nearest double and kept as written; `None` when it overflows.
    fn read_number(&mut self) -> Option<JsonNumber> {
        let start = self.at;
        self.eat(b'-');
        match self.peek()? {
            b'0' => self.at += 1,
            b'1'..=b'9' => self.skip_digits(),
            _ => return None,
        }
        if self.eat(b'.') {
            self.require_digits()?;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            self.require_digits()?;
        }
        let literal = &self.text[start..self.at];
        let value: f64 = literal.parse().ok()?;
        value.is_finite().then(|| JsonNumber {
            value,
            literal: literal.into(),
        })
    }

    fn skip_digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
    }

    fn require_digits(&mut self) -> Option<()> {
        let start = self.at;
        self.skip_digits();
        (self.at > start).then_some(())
    }

    /// A string from its opening quote. Foundation drops one U+FEFF at the
    /// start of the string it reads, whether written raw or as `\ufeff`.
    fn read_string(&mut self) -> Option<String> {
        self.at += 1;
        let mut out = String::new();
        let mut run = self.at;
        loop {
            match self.peek()? {
                b'"' => {
                    out.push_str(&self.text[run..self.at]);
                    self.at += 1;
                    if out.starts_with('\u{FEFF}') {
                        out.drain(..'\u{FEFF}'.len_utf8());
                    }
                    return Some(out);
                }
                b'\\' => {
                    out.push_str(&self.text[run..self.at]);
                    self.at += 1;
                    out.push(self.read_escape()?);
                    run = self.at;
                }
                0x00..=0x1F => return None,
                _ => self.at += 1,
            }
        }
    }

    /// The character an escape (after its backslash) stands for.
    fn read_escape(&mut self) -> Option<char> {
        let escape = self.peek()?;
        self.at += 1;
        Some(match escape {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{8}',
            b'f' => '\u{c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => {
                let unit = self.read_hex4()?;
                match unit {
                    0xD800..=0xDBFF => {
                        if !(self.eat(b'\\') && self.eat(b'u')) {
                            return None;
                        }
                        let low = self.read_hex4()?;
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return None;
                        }
                        char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))?
                    }
                    0xDC00..=0xDFFF => return None,
                    _ => char::from_u32(unit)?,
                }
            }
            _ => return None,
        })
    }

    fn read_hex4(&mut self) -> Option<u32> {
        let digits = self.text.get(self.at..self.at + 4)?;
        if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        self.at += 4;
        u32::from_str_radix(digits, 16).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_str(text: &str) -> Option<JsonValue> {
        read(text.as_bytes())
    }

    /// A number by value (its literal plays no part in equality or in
    /// `write`).
    fn num(value: f64) -> JsonValue {
        JsonValue::Number(JsonNumber {
            value,
            literal: "unused".into(),
        })
    }

    #[test]
    fn the_first_of_two_equal_keys_wins() {
        let value = read_str(r#"{"subtype":"a","subtype":"b"}"#).unwrap();
        assert_eq!(value.get("subtype").and_then(JsonValue::as_str), Some("a"));
    }

    #[test]
    fn one_leading_byte_order_mark_is_skipped() {
        assert!(read(b"\xEF\xBB\xBF{}").is_some());
        assert!(read(b"\xEF\xBB\xBF\xEF\xBB\xBF{}").is_none());
        assert!(read(b"\xEF\xBB\xBF").is_none());
        assert!(read(b" \xEF\xBB\xBF{}").is_none());
    }

    #[test]
    fn a_value_may_begin_inside_at_most_512_open_containers() {
        let deep = |opened: usize, inner: &str| {
            format!("{}{inner}{}", "[".repeat(opened), "]".repeat(opened))
        };
        assert!(read_str(&deep(513, "")).is_some());
        assert!(read_str(&deep(514, "")).is_none());
        assert!(read_str(&deep(512, "1")).is_some());
        assert!(read_str(&deep(513, "1")).is_none());
        assert!(read_str(&deep(511, r#"{"a":1}"#)).is_some());
        assert!(read_str(&deep(512, r#"{"a":1}"#)).is_none());
        assert!(read_str(&deep(512, "{}")).is_some());
        let objects = |opened: usize, inner: &str| {
            format!("{}{inner}{}", r#"{"a":"#.repeat(opened), "}".repeat(opened))
        };
        assert!(read_str(&objects(512, "{}")).is_some());
        assert!(read_str(&objects(512, "1")).is_some());
        assert!(read_str(&objects(513, "1")).is_none());
    }

    #[test]
    fn a_deep_line_does_not_use_the_call_stack() {
        let worker = std::thread::Builder::new()
            .stack_size(64 * 1024)
            .spawn(|| {
                let line = format!("{}{}", "[".repeat(512), "]".repeat(512));
                let deep = read_str(&line).is_some();
                let objects = format!("{}1{}", r#"{"a":"#.repeat(512), "}".repeat(512));
                deep && read_str(&objects).is_some()
            })
            .unwrap();
        assert!(worker.join().unwrap());
    }

    #[test]
    fn numbers_read_like_foundation() {
        let number =
            |text: &str| read_str(&format!(r#"{{"n":{text}}}"#)).map(|v| v.get("n").cloned());
        assert_eq!(number("1e400"), None);
        assert_eq!(number("1e-400"), Some(Some(num(0.0))));
        assert_eq!(
            number("123456789012345678901234567890"),
            Some(Some(num(1.234_567_890_123_456_8e29)))
        );
        assert_eq!(number("1E+2"), Some(Some(num(100.0))));
        for rejected in ["01", "1.", ".5", "+1", "1e", "-", "NaN", "1e+", "-01"] {
            assert_eq!(number(rejected), None, "{rejected}");
        }
    }

    #[test]
    fn strings_read_like_foundation() {
        let string = |text: &str| {
            read_str(&format!(r#"{{"s":{text}}}"#))
                .and_then(|v| v.get("s").and_then(JsonValue::as_str).map(str::to_owned))
        };
        assert_eq!(string(r#""😀é\/""#).as_deref(), Some("😀é/"));
        assert_eq!(string(r#""a\u0000b""#).as_deref(), Some("a\u{0}b"));
        assert_eq!(string("\"\u{7f}\"").as_deref(), Some("\u{7f}"));
        for rejected in [
            r#""\ud800""#,
            r#""\udc00""#,
            r#""\ud800A""#,
            r#""\x""#,
            "\"a\tb\"",
            "'a'",
        ] {
            assert_eq!(string(rejected), None, "{rejected}");
        }
    }

    #[test]
    fn the_root_is_an_object_or_an_array_alone() {
        assert!(read_str(" \t\r\n{} \r").is_some());
        assert!(read_str("[1,2]").is_some());
        for rejected in [
            "\"x\"",
            "1",
            "null",
            "{} x",
            "{}\u{0}",
            "{}\u{c}",
            "\u{b}{}",
            "",
            "{\"a\":1 /* c */}",
        ] {
            assert!(read_str(rejected).is_none(), "{rejected:?}");
        }
    }

    #[test]
    fn one_trailing_comma_is_accepted() {
        assert!(read_str(r#"{"a":1,}"#).is_some());
        assert!(read_str(r#"{"a":[1 , ],"b":{"c":1,} , }"#).is_some());
        for rejected in [
            "{,}",
            "[,]",
            r#"{"a":1,,}"#,
            "[1,,2]",
            "[1,,]",
            r#"{"a":1,"#,
        ] {
            assert!(read_str(rejected).is_none(), "{rejected}");
        }
    }

    #[test]
    fn one_leading_feff_of_a_string_is_dropped() {
        let string = |text: &str| {
            read_str(&format!(r#"{{"s":{text}}}"#))
                .and_then(|v| v.get("s").and_then(JsonValue::as_str).map(str::to_owned))
        };
        assert_eq!(string("\"\u{FEFF}hi\"").as_deref(), Some("hi"));
        assert_eq!(string(r#""\ufeffhi""#).as_deref(), Some("hi"));
        assert_eq!(
            string("\"\u{FEFF}\u{FEFF}hi\"").as_deref(),
            Some("\u{FEFF}hi")
        );
        assert_eq!(string(r#""\ufeff\ufeffhi""#).as_deref(), Some("\u{FEFF}hi"));
        assert_eq!(string(r#""\ufeff""#).as_deref(), Some(""));
        assert_eq!(string("\"\u{FEFF}\\u0041\"").as_deref(), Some("A"));
        assert_eq!(string("\"a\u{FEFF}b\"").as_deref(), Some("a\u{FEFF}b"));
        assert_eq!(string("\"\\\\\u{FEFF}x\"").as_deref(), Some("\\\u{FEFF}x"));
        let key = read_str("{\"\u{FEFF}type\":\"t\"}").unwrap();
        assert_eq!(key.get("type").and_then(JsonValue::as_str), Some("t"));
        let empty = read_str("{\"\u{FEFF}\":1}").unwrap();
        assert!(empty.get("").is_some());
    }

    #[test]
    fn a_stray_a9_inside_a_string_reads_as_a_replacement() {
        let string = |bytes: &[u8]| {
            let mut line = br#"{"s":""#.to_vec();
            line.extend_from_slice(bytes);
            line.extend_from_slice(br#""}"#);
            read(&line).map(|v| v.get("s").and_then(JsonValue::as_str).map(str::to_owned))
        };
        assert_eq!(string(b"s\xA9x"), Some(Some("s\u{FFFD}x".to_owned())));
        assert_eq!(
            string(b"\xA9\xA9"),
            Some(Some("\u{FFFD}\u{FFFD}".to_owned()))
        );
        assert_eq!(
            string(b"\xC3\xA9\xA9"),
            Some(Some("\u{E9}\u{FFFD}".to_owned()))
        );
        assert_eq!(string(b"\\n\xA9"), Some(Some("\n\u{FFFD}".to_owned())));
        // A string's leading U+FEFF is still dropped; A9 in a key reads too.
        assert_eq!(
            string(b"\xEF\xBB\xBF\xA9"),
            Some(Some("\u{FFFD}".to_owned()))
        );
        let key = read(b"{\"s\xA9\":1}").unwrap();
        assert!(key.get("s\u{FFFD}").is_some());
        // Every other stray byte, and A9 outside a string, rejects the line.
        assert_eq!(string(b"s\xA8x"), None);
        assert_eq!(string(b"\xE2\xA9x"), None);
        assert_eq!(string(b"\\\xA9"), None);
        assert!(read(b"{\"s\":1\xA9}").is_none());
        assert!(read(b"\xA9{}").is_none());
        // A quote inside a string does not end it after a backslash.
        assert!(read(b"{\"s\":\"\\\"\xA9\"}").is_some());
        assert!(read(b"{\"s\":\"\\\\\"\xA9}").is_none());
    }

    #[test]
    fn only_utf8_is_read() {
        assert!(read(b"{\"a\":\"\xFF\"}").is_none());
        assert!(read(b"{\"a\":\"\xC0\xAF\"}").is_none());
        assert!(read(b"{\"a\":\"\xED\xA0\x80\"}").is_none());
        // Foundation would detect UTF-16 here; the CLI never writes it.
        assert!(read(b"{\x00}\x00").is_none());
    }

    fn field(text: &str) -> JsonValue {
        let mut root = read_str(&format!(r#"{{"f":{text}}}"#)).unwrap();
        match &mut root {
            JsonValue::Object(members) => members.remove(0).1,
            _ => unreachable!(),
        }
    }

    #[test]
    fn swift_int_reads_like_nsnumber() {
        // Measured with Swift 5.9.2 on macOS 27.2 (`as? Int`).
        for (text, int) in [
            ("1", Some(1)),
            ("1.0", Some(1)),
            ("1e2", Some(100)),
            ("1.5", None),
            ("true", Some(1)),
            ("false", Some(0)),
            ("-3", Some(-3)),
            ("1e19", None),
            ("\"1\"", None),
            ("null", None),
            ("-9223372036854775808", Some(i64::MIN)),
            ("100000000000000000000", None),
            ("[1]", None),
        ] {
            assert_eq!(field(text).as_swift_int(), int, "{text}");
        }
    }

    #[test]
    fn swift_int_value_truncates_and_saturates() {
        // Measured with Swift 5.9.2 on macOS 27.2 (`(as? NSNumber)?.intValue`).
        for (text, int) in [
            ("1", Some(1)),
            ("1.5", Some(1)),
            ("1.9", Some(1)),
            ("-1.9", Some(-1)),
            ("true", Some(1)),
            ("false", Some(0)),
            ("1e19", Some(i64::MAX)),
            ("-1e19", Some(i64::MIN)),
            ("\"5\"", None),
            ("null", None),
            ("{}", None),
        ] {
            assert_eq!(field(text).as_swift_int_value(), int, "{text}");
        }
    }

    #[test]
    fn an_array_with_one_non_object_is_not_an_object_array() {
        assert_eq!(
            field(r#"[{"a":1},{}]"#).as_object_array().map(|a| a.len()),
            Some(2)
        );
        assert_eq!(field("[]").as_object_array().map(|a| a.len()), Some(0));
        assert!(field(r#"[{"a":1},5]"#).as_object_array().is_none());
        assert!(field(r#"[{"a":1},null]"#).as_object_array().is_none());
        assert!(field(r#"{"a":1}"#).as_object_array().is_none());
    }

    fn string(text: &str) -> JsonValue {
        JsonValue::String(text.to_owned())
    }

    #[test]
    fn write_escapes_like_swift() {
        let value = JsonValue::Object(vec![("cwd".to_owned(), string("/tmp/a b\n\u{1}é\"\\"))]);
        assert_eq!(
            write(&value).unwrap(),
            "{\"cwd\":\"\\/tmp\\/a b\\n\\u0001é\\\"\\\\\"}"
        );
    }

    #[test]
    fn write_keeps_member_order() {
        let value = JsonValue::Object(vec![
            ("jsonrpc".to_owned(), string("2.0")),
            ("id".to_owned(), num(3.0)),
            ("method".to_owned(), string("m")),
            (
                "params".to_owned(),
                JsonValue::Array(vec![
                    JsonValue::Null,
                    JsonValue::Bool(true),
                    num(-1.5),
                    num(1e20),
                    JsonValue::Object(Vec::new()),
                    JsonValue::Array(Vec::new()),
                ]),
            ),
        ]);
        assert_eq!(
            write(&value).unwrap(),
            r#"{"jsonrpc":"2.0","id":3,"method":"m","params":[null,true,-1.5,1e+20,{},[]]}"#
        );
    }

    #[test]
    fn write_keeps_the_first_of_two_equal_keys() {
        let value = read_str(r#"{"a":1,"b":2,"a":3}"#).unwrap();
        assert_eq!(write(&value).unwrap(), r#"{"a":1,"b":2}"#);
    }

    #[test]
    fn a_wide_object_is_written_in_one_pass() {
        // An agent's id is echoed as read, so its width is the agent's to
        // choose; a check per member against every other one took minutes
        // at a few hundred thousand keys.
        let members: Vec<String> = (0..200_000)
            .map(|index| format!(r#""k{index}":0"#))
            .collect();
        let line = format!("{{{},\"k0\":1}}", members.join(","));
        let value = read_str(&line).unwrap();
        let expected = format!("{{{}}}", members.join(","));
        assert_eq!(write(&value).unwrap(), expected);
    }

    #[test]
    fn a_deep_value_is_written_without_the_call_stack() {
        let worker = std::thread::Builder::new()
            .stack_size(64 * 1024)
            .spawn(|| {
                let line = format!("{}{}", "[".repeat(512), "]".repeat(512));
                let deep = read_str(&line).map(|value| write(&value));
                let objects = format!("{}1{}", r#"{"a":"#.repeat(512), "}".repeat(512));
                let deep_objects = read_str(&objects).map(|value| write(&value));
                (deep, line, deep_objects, objects)
            })
            .unwrap();
        let (deep, line, deep_objects, objects) = worker.join().unwrap();
        assert_eq!(deep.unwrap().unwrap(), line);
        assert_eq!(deep_objects.unwrap().unwrap(), objects);
    }

    #[test]
    fn write_verbatim_keeps_every_literal() {
        let text = r#"{"a":1.0,"b":0.1,"c":-0,"d":-0.0,"e":12345678901234567890123,"f":1E+2,"g":[1e-400]}"#;
        let value = read_str(text).unwrap();
        assert_eq!(write_verbatim(&value).unwrap(), text);
    }

    #[test]
    fn write_verbatim_keeps_the_first_of_two_equal_keys() {
        let value = read_str(r#"{"a":1,"b":{"c":1,"c":2},"a":3}"#).unwrap();
        assert_eq!(write_verbatim(&value).unwrap(), r#"{"a":1,"b":{"c":1}}"#);
    }

    #[test]
    fn write_verbatim_restores_the_feff_foundation_drops() {
        let text = "{\"\u{FEFF}k\":\"\u{FEFF}\u{FEFF}v\",\"w\":\"x\u{FEFF}\"}";
        let value = read_str(text).unwrap();
        let written = write_verbatim(&value).unwrap();
        assert_eq!(written, "{\"k\":\"\u{FEFF}\u{FEFF}v\",\"w\":\"x\u{FEFF}\"}");
        // Read back as Foundation reads it, the values are the first read's.
        assert_eq!(read_str(&written).unwrap(), value);
    }

    #[test]
    fn write_verbatim_escapes_strings_as_write_does() {
        let value = read_str(r#"{"s":"a\/b \u0001 \u0000 \u007f é","k/":"\""}"#).unwrap();
        assert_eq!(
            write_verbatim(&value).unwrap(),
            "{\"s\":\"a\\/b \\u0001 \\u0000 \u{7f} é\",\"k\\/\":\"\\\"\"}"
        );
    }

    #[test]
    fn a_deep_value_is_written_verbatim_without_the_call_stack() {
        let worker = std::thread::Builder::new()
            .stack_size(64 * 1024)
            .spawn(|| {
                let line = format!("{{\"d\":{}0.10{}}}", "[".repeat(511), "]".repeat(511));
                let written = read_str(&line).map(|value| write_verbatim(&value));
                (written, line)
            })
            .unwrap();
        let (written, line) = worker.join().unwrap();
        assert_eq!(written.unwrap().unwrap(), line);
    }

    #[test]
    fn write_then_read_round_trips() {
        let text = r#"{"s":"a\/b \u0001 😀","n":[0,-7,1.25,9007199254740993],"o":{"t":true,"f":false,"z":null}}"#;
        let value = read_str(text).unwrap();
        let written = write(&value).unwrap();
        assert_eq!(read_str(&written).unwrap(), value);
    }

    #[test]
    fn swift_reads_bools_and_numbers_through_nsnumber() {
        let field = |text: &str| read_str(&format!(r#"{{"f":{text}}}"#)).unwrap();
        let get = |text: &str| field(text).get("f").cloned().unwrap();
        assert_eq!(get("1").as_swift_bool(), Some(true));
        assert_eq!(get("1.0").as_swift_bool(), Some(true));
        assert_eq!(get("0").as_swift_bool(), Some(false));
        assert_eq!(get("-0.0").as_swift_bool(), Some(false));
        assert_eq!(get("2").as_swift_bool(), None);
        assert_eq!(get("\"true\"").as_swift_bool(), None);
        assert_eq!(get("true").as_swift_number(), Some(1.0));
        assert_eq!(get("false").as_swift_number(), Some(0.0));
        assert_eq!(get("\"0.5\"").as_swift_number(), None);
        assert_eq!(get("null").as_swift_number(), None);
        assert_eq!(get("5").as_str(), None);
    }
}
