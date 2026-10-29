//! JSON text byte for byte as Swift's `JSONEncoder` writes it (HK-414):
//! config.json with `[.prettyPrinted, .sortedKeys]`, and a transcript line
//! with the default formatting (compact, no space around `:` or `,`).
//!
//! - Pretty printing indents by two spaces, writes `"key" : value` with a
//!   space on each side of the colon, `,\n` between members, an empty
//!   object as `{`, a blank line and `}` at the parent's indent (an empty
//!   array likewise), and no trailing newline.
//! - Strings escape `"`, `\`, `/` (as `\/`), `\b \f \n \r \t` and the other
//!   C0 controls as lowercase `\u00xx`; DEL and all non-ASCII are raw (the
//!   rules `wire` already shares with serde_json).
//! - `.sortedKeys` orders keys by Unicode scalar, which is byte order and
//!   Rust's `str` order. This writer keeps the order it is given, so callers
//!   pass sorted maps (`BTreeMap`) and declare struct fields sorted.
//! - Integers are decimal. A `Float` or `Double` is written with the shortest
//!   digits that read back as the same value (Swift's `description`), in
//!   exponential form `d.ddde±XX` when the decimal exponent is below -4 or the
//!   magnitude is above 2^24 (`Float`) or 2^53 (`Double`), and in plain
//!   decimal otherwise, without a trailing `.0`; zero is `0` or `-0`.

use std::io;

use serde::Serialize;
use serde_json::ser::{Formatter, Serializer};

use crate::wire::write_slash_escaped;
use crate::CoreError;

/// `JSONEncoder` with `.prettyPrinted` (the caller supplies sorted keys).
pub(crate) fn to_swift_pretty<T: Serialize + ?Sized>(value: &T) -> Result<String, CoreError> {
    write(value, true)
}

/// `JSONEncoder` with its default formatting: compact, members in the order
/// given. (Without `.sortedKeys` Swift's order was a hash order that changed
/// from one launch to the next, so a caller fixes one, HK-416.)
pub(crate) fn to_swift_compact<T: Serialize + ?Sized>(value: &T) -> Result<String, CoreError> {
    write(value, false)
}

fn write<T: Serialize + ?Sized>(value: &T, pretty: bool) -> Result<String, CoreError> {
    let mut out = Vec::new();
    let formatter = SwiftEncoderFormatter {
        pretty,
        indent: 0,
        has_value: false,
    };
    let mut serializer = Serializer::with_formatter(&mut out, formatter);
    value
        .serialize(&mut serializer)
        .map_err(|error| CoreError::Failed {
            message: format!("could not write JSON: {error}"),
        })?;
    String::from_utf8(out).map_err(|error| CoreError::Failed {
        message: format!("JSON writer produced invalid UTF-8: {error}"),
    })
}

/// 2^24: above it a `Float` is written in exponential form.
const FLOAT_PLAIN_LIMIT: f64 = 16_777_216.0;

/// 2^53: above it a `Double` is written in exponential form.
const DOUBLE_PLAIN_LIMIT: f64 = 9_007_199_254_740_992.0;

/// A `Float` as `JSONEncoder` writes it.
pub(crate) fn swift_f32(value: f32) -> String {
    swift_float(
        &format!("{value:e}"),
        f64::from(value).abs() > FLOAT_PLAIN_LIMIT,
    )
}

/// A `Double` as `JSONEncoder` writes it.
pub(crate) fn swift_f64(value: f64) -> String {
    swift_float(&format!("{value:e}"), value.abs() > DOUBLE_PLAIN_LIMIT)
}

/// Lays out Rust's shortest exponential text (`-1.5e-7`, `0e0`) the way
/// Swift's `description` does, minus its trailing `.0`.
fn swift_float(shortest: &str, large: bool) -> String {
    let (negative, unsigned) = match shortest.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, shortest),
    };
    let (mantissa, exponent) = unsigned.split_once('e').unwrap_or((unsigned, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if digits.bytes().all(|digit| digit == b'0') {
        return format!("{sign}0");
    }
    if exponent < -4 || large {
        let (first, rest) = digits.split_at(1);
        let point = if rest.is_empty() { "" } else { "." };
        let exponent_sign = if exponent < 0 { '-' } else { '+' };
        return format!(
            "{sign}{first}{point}{rest}e{exponent_sign}{:02}",
            exponent.unsigned_abs()
        );
    }
    if exponent < 0 {
        let zeros = "0".repeat(usize::try_from(-exponent - 1).unwrap_or(0));
        return format!("{sign}0.{zeros}{digits}");
    }
    let whole = usize::try_from(exponent).unwrap_or(0) + 1;
    if digits.len() <= whole {
        format!("{sign}{digits}{}", "0".repeat(whole - digits.len()))
    } else {
        format!("{sign}{}.{}", &digits[..whole], &digits[whole..])
    }
}

/// serde_json's output reshaped into `JSONEncoder`'s.
struct SwiftEncoderFormatter {
    pretty: bool,
    indent: usize,
    has_value: bool,
}

impl SwiftEncoderFormatter {
    fn newline_and_indent<W: ?Sized + io::Write>(&self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b"\n")?;
        for _ in 0..self.indent {
            writer.write_all(b"  ")?;
        }
        Ok(())
    }

    fn open<W: ?Sized + io::Write>(&mut self, writer: &mut W, bracket: &[u8]) -> io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(bracket)
    }

    fn close<W: ?Sized + io::Write>(&mut self, writer: &mut W, bracket: &[u8]) -> io::Result<()> {
        self.indent = self.indent.saturating_sub(1);
        if self.pretty {
            if !self.has_value {
                // JSONEncoder leaves a blank line inside an empty container.
                writer.write_all(b"\n")?;
            }
            self.newline_and_indent(writer)?;
        }
        writer.write_all(bracket)
    }

    fn separate<W: ?Sized + io::Write>(&mut self, writer: &mut W, first: bool) -> io::Result<()> {
        if !first {
            writer.write_all(b",")?;
        }
        if self.pretty {
            self.newline_and_indent(writer)?;
        }
        Ok(())
    }
}

impl Formatter for SwiftEncoderFormatter {
    // serde_json writes a non-finite number as null without calling these;
    // callers refuse one first, as JSONEncoder throws on it.
    fn write_f32<W: ?Sized + io::Write>(&mut self, writer: &mut W, value: f32) -> io::Result<()> {
        writer.write_all(swift_f32(value).as_bytes())
    }

    fn write_f64<W: ?Sized + io::Write>(&mut self, writer: &mut W, value: f64) -> io::Result<()> {
        writer.write_all(swift_f64(value).as_bytes())
    }

    fn write_string_fragment<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        fragment: &str,
    ) -> io::Result<()> {
        write_slash_escaped(writer, fragment)
    }

    fn begin_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.open(writer, b"[")
    }

    fn end_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.close(writer, b"]")
    }

    fn begin_array_value<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.separate(writer, first)
    }

    fn end_array_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn begin_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.open(writer, b"{")
    }

    fn end_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.close(writer, b"}")
    }

    fn begin_object_key<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.separate(writer, first)
    }

    fn begin_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        writer.write_all(if self.pretty { b" : " } else { b":" })
    }

    fn end_object_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn floats_are_written_like_swift() {
        // Measured with JSONEncoder (Swift 5.9.2, macOS 27.2).
        for (value, text) in [
            (0.5f32, "0.5"),
            (1.0, "1"),
            (0.55, "0.55"),
            (0.1, "0.1"),
            (0.333_333_34, "0.33333334"),
            (0.0001, "0.0001"),
            (0.000_11, "0.00011"),
            (0.000_123, "0.000123"),
            (9.999_999e-5, "9.999999e-05"),
            (1e-5, "1e-05"),
            (1e-7, "1e-07"),
            (1e-40, "1e-40"),
            (1e-45, "1e-45"),
            (16_777_216.0, "16777216"),
            (16_777_218.0, "1.6777218e+07"),
            (1e10, "1e+10"),
            (f32::MAX, "3.4028235e+38"),
            (0.0, "0"),
            (-0.0, "-0"),
            (-1.5, "-1.5"),
            (1234.5, "1234.5"),
        ] {
            assert_eq!(swift_f32(value), text, "{value:e}");
        }
        for (value, text) in [
            (9_007_199_254_740_992.0f64, "9007199254740992"),
            (9_007_199_254_740_994.0, "9.007199254740994e+15"),
            (1e16, "1e+16"),
            (5e-324, "5e-324"),
            (f64::MAX, "1.7976931348623157e+308"),
            (1_761_700_000.123_456, "1761700000.123456"),
            (1_761_700_000.0, "1761700000"),
            (0.1, "0.1"),
            (1e-5, "1e-05"),
        ] {
            assert_eq!(swift_f64(value), text, "{value:e}");
        }
    }

    #[test]
    fn pretty_output_matches_jsonencoder() {
        let value = json!({"a": {}, "b": [], "c": [1, "x/y"], "d": {"e": {"f": {}}}});
        assert_eq!(
            to_swift_pretty(&value).unwrap(),
            "{\n  \"a\" : {\n\n  },\n  \"b\" : [\n\n  ],\n  \"c\" : [\n    1,\n    \"x\\/y\"\n  ],\n  \"d\" : {\n    \"e\" : {\n      \"f\" : {\n\n      }\n    }\n  }\n}"
        );
        assert_eq!(to_swift_pretty(&json!({})).unwrap(), "{\n\n}");
    }

    #[test]
    fn compact_output_matches_jsonencoder() {
        let value = json!({"a": {}, "b": [], "c": [1, "x/y", 0.5], "d": {"e": true}});
        assert_eq!(
            to_swift_compact(&value).unwrap(),
            r#"{"a":{},"b":[],"c":[1,"x\/y",0.5],"d":{"e":true}}"#
        );
    }
}
