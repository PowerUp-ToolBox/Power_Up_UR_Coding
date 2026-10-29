//! JSON text written byte for byte as Swift's `JSONEncoder` writes it.
//!
//! The Swift app and the core must agree on the exact bytes of anything that
//! is stored, or a file written by one reads as changed to the other. serde_json
//! escapes exactly what `JSONEncoder` escapes (`"`, `\`, the C0 controls with
//! the short forms and lowercase `\u00xx`), except `/`: Swift writes `\/`,
//! serde_json writes it raw. The formatter here adds that one escape, and the
//! pretty config writer (`json::encoder`) shares it.

use std::io;

use serde::Serialize;
use serde_json::ser::{Formatter, Serializer};

use crate::CoreError;

/// Compact JSON (no spaces) with Swift's escaping. Keys come out in the order
/// the value serializes them; a `serde_json::Map` is sorted, which matches
/// `.sortedKeys` for ASCII keys.
pub fn to_swift_json<T: Serialize + ?Sized>(value: &T) -> Result<String, CoreError> {
    let mut out = Vec::new();
    let mut serializer = Serializer::with_formatter(&mut out, SwiftCompactFormatter);
    value
        .serialize(&mut serializer)
        .map_err(|error| CoreError::Failed {
            message: format!("could not write JSON: {error}"),
        })?;
    String::from_utf8(out).map_err(|error| CoreError::Failed {
        message: format!("JSON writer produced invalid UTF-8: {error}"),
    })
}

/// serde_json's compact output, with `/` written as `\/`. serde_json never
/// escapes `/`, so it always arrives inside an unescaped fragment.
struct SwiftCompactFormatter;

impl Formatter for SwiftCompactFormatter {
    fn write_string_fragment<W>(&mut self, writer: &mut W, fragment: &str) -> io::Result<()>
    where
        W: ?Sized + io::Write,
    {
        write_slash_escaped(writer, fragment)
    }
}

/// Writes an unescaped string fragment from serde_json with `/` as `\/`, as
/// Swift's `JSONEncoder` writes it. serde_json escapes everything else the
/// way Swift does.
pub(crate) fn write_slash_escaped<W>(writer: &mut W, fragment: &str) -> io::Result<()>
where
    W: ?Sized + io::Write,
{
    for (index, part) in fragment.split('/').enumerate() {
        if index > 0 {
            writer.write_all(b"\\/")?;
        }
        writer.write_all(part.as_bytes())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slashes_are_escaped_like_swift() {
        let text = to_swift_json("a/b//c").unwrap();
        assert_eq!(text, r#""a\/b\/\/c""#);
        assert_eq!(to_swift_json("/").unwrap(), r#""\/""#);
    }

    #[test]
    fn controls_use_short_forms_and_lowercase_hex() {
        let text = to_swift_json("\u{1}\u{1f}\u{8}\u{c}\n\r\t\"\\").unwrap();
        assert_eq!(text, r#""\u0001\u001f\b\f\n\r\t\"\\""#);
    }

    #[test]
    fn del_line_separator_and_non_ascii_stay_raw() {
        let text = to_swift_json("\u{7f}\u{2028}修复 🚀").unwrap();
        assert_eq!(text, "\"\u{7f}\u{2028}修复 🚀\"");
    }

    #[test]
    fn output_is_compact() {
        let value = serde_json::json!({"b": [1, 2], "a": {}});
        assert_eq!(to_swift_json(&value).unwrap(), r#"{"a":{},"b":[1,2]}"#);
    }
}
