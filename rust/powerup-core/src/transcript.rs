//! The per-project transcript history as JSON Lines (DESIGN v1.6, v2.14):
//! how an entry is written as a line, how a stored line and a whole file
//! read back, and what each project's file is called. The platform keeps
//! the file itself (the transcripts folder, the append, the atomic rewrite,
//! the standardized project path) and hands the core bytes and strings.
//!
//! Lines are read as Swift's `JSONDecoder` read a `TranscriptEntry` (so
//! every line an older build wrote loads) and written as its `JSONEncoder`
//! wrote one, except for the member order: Swift's was a hash order that
//! changed from one launch to the next, so the core fixes it (HK-416).

use serde::Serialize;
use unicode_segmentation::UnicodeSegmentation;

use crate::json::decoder;
use crate::json::encoder::to_swift_compact;
use crate::{sha256, text, CoreError};

/// Who an entry is from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscriptKind {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

impl TranscriptKind {
    /// The name a line stores.
    pub fn name(self) -> &'static str {
        match self {
            TranscriptKind::User => "user",
            TranscriptKind::Assistant => "assistant",
            TranscriptKind::Tool => "tool",
            TranscriptKind::System => "system",
            TranscriptKind::Error => "error",
        }
    }

    /// The kind a stored name spells exactly; a kind from a future build is
    /// `None`, so its line is skipped rather than guessed.
    pub fn from_name(name: &str) -> Option<TranscriptKind> {
        Some(match name {
            "user" => TranscriptKind::User,
            "assistant" => TranscriptKind::Assistant,
            "tool" => TranscriptKind::Tool,
            "system" => TranscriptKind::System,
            "error" => TranscriptKind::Error,
            _ => return None,
        })
    }
}

/// One transcript entry.
#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptEntry {
    /// The entry's UUID as `uuidString` spells it (uppercase).
    pub id: String,
    pub kind: TranscriptKind,
    pub text: String,
    /// Seconds since 1970, as the line holds them.
    pub date_seconds: f64,
}

/// A file that has grown past this many entries is rewritten with only the
/// newest ones when it is next loaded (HK-176).
pub const MAX_STORED_ENTRIES: usize = 2000;

/// How many entries a restore brings back by default (HK-176).
pub const DEFAULT_RESTORE_COUNT: usize = 200;

/// Seconds between 1970 and Foundation's reference date (2001).
const SECONDS_FROM_1970_TO_2001: f64 = 978_307_200.0;

/// The line's members, in the order the core writes them.
#[derive(Serialize)]
struct Line<'a> {
    id: &'a str,
    kind: &'static str,
    text: &'a str,
    date: f64,
}

/// One JSONL line for `entry`, with its LF: a compact object with the
/// members id, kind, text and date in that order, escaped as JSONEncoder
/// escapes (`/` as `\/`), the date as Swift writes a Double. The id is
/// written as given (the app passes `uuidString`).
pub fn entry_line(entry: &TranscriptEntry) -> Result<String, CoreError> {
    line_with_date(entry, entry.date_seconds)
}

fn line_with_date(entry: &TranscriptEntry, date: f64) -> Result<String, CoreError> {
    if !date.is_finite() {
        // JSONEncoder throws on a non-finite Double; a Date never holds one.
        return Err(CoreError::Failed {
            message: format!("a transcript date must be finite, not {date}"),
        });
    }
    let mut line = to_swift_compact(&Line {
        id: &entry.id,
        kind: entry.kind.name(),
        text: &entry.text,
        date,
    })?;
    line.push('\n');
    Ok(line)
}

/// One stored line (without its LF) as JSONDecoder read a TranscriptEntry
/// with `.secondsSince1970` dates, or `None` when the line is skipped: the
/// line must scan (`json::decoder`), its root be an object whose keys all
/// convert, `id` a string `UUID(uuidString:)` accepts (returned uppercase),
/// `kind` a name spelled exactly, `text` a string and `date` a Double.
/// Other members are ignored and never converted; of equal keys the first
/// wins.
pub fn decode_line(line: &[u8]) -> Option<TranscriptEntry> {
    let root = decoder::read_document(line)?;
    let members = root.keyed()?;
    let id = uuid_string(&members.get("id")?.as_string()?)?;
    let kind = TranscriptKind::from_name(&members.get("kind")?.as_string()?)?;
    let text = members.get("text")?.as_string()?;
    let date_seconds = members.get("date")?.as_double()?;
    Some(TranscriptEntry {
        id,
        kind,
        text,
        date_seconds,
    })
}

/// `UUID(uuidString:)` then `uuidString`: exactly 36 ASCII characters, hex
/// digits of either case in groups of 8-4-4-4-12 split by hyphens; no
/// braces, no compact form, no surrounding space. Uppercased. Foundation
/// hands the text to `uuid_parse` as a C string, so it ends at the first
/// NUL: a valid id followed by `\u0000` and anything reads as that id
/// (found by the differential against the old Swift reader).
fn uuid_string(text: &str) -> Option<String> {
    let text = text.split('\0').next().unwrap_or_default();
    let bytes = text.as_bytes();
    let shaped = bytes.len() == 36
        && bytes.iter().enumerate().all(|(at, byte)| match at {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        });
    shaped.then(|| text.to_ascii_uppercase())
}

/// What loading a transcript file found.
#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptLoad {
    /// The newest entries asked for, oldest first.
    pub entries: Vec<TranscriptEntry>,
    /// When the file held more than [`MAX_STORED_ENTRIES`] entries: the
    /// text to replace it with (the newest ones), which the platform
    /// writes atomically.
    pub rewrite: Option<String>,
}

/// A whole transcript file: split on LF with empty pieces dropped, each
/// piece read with [`decode_line`] and skipped when it does not decode;
/// past [`MAX_STORED_ENTRIES`] entries the newest ones are kept and
/// `rewrite` holds their lines; then the newest `max_entries`, oldest first.
pub fn load_tail(file: &[u8], max_entries: usize) -> TranscriptLoad {
    let mut entries: Vec<TranscriptEntry> = file
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .filter_map(decode_line)
        .collect();

    let mut rewrite = None;
    if entries.len() > MAX_STORED_ENTRIES {
        entries.drain(..entries.len() - MAX_STORED_ENTRIES);
        // Swift rewrote the entries it held, and a Date holds its seconds
        // from 2001, so a date the subtraction rounds (0.1, say) was written
        // back as the Date's own seconds; an entry that cannot be written is
        // left out, as Swift's encoder loop skipped it.
        rewrite = Some(
            entries
                .iter()
                .filter_map(|entry| line_with_date(entry, as_a_date_holds(entry.date_seconds)).ok())
                .collect::<String>(),
        );
    }

    let keep_from = entries.len().saturating_sub(max_entries);
    entries.drain(..keep_from);
    TranscriptLoad { entries, rewrite }
}

/// `Date(timeIntervalSince1970: seconds).timeIntervalSince1970`: the
/// seconds through Foundation's reference date and back.
fn as_a_date_holds(seconds: f64) -> f64 {
    (seconds - SECONDS_FROM_1970_TO_2001) + SECONDS_FROM_1970_TO_2001
}

/// The file name of a project's transcript (HK-174): `<slug>-<hash>.jsonl`,
/// or `<hash>.jsonl` when the slug is empty, so two folders of the same
/// name never share a history. `standardized_path` is the path as the
/// platform standardizes it (on macOS that also decomposes accents); the
/// core hashes its bytes as given.
///
/// - hash: the first 6 bytes of SHA-256 of the path's UTF-8, lowercase hex.
/// - slug: the last path component (less one leading U+FEFF, as
///   `URL.lastPathComponent` returns it), lowercased scalar by scalar, each
///   Character kept when its first scalar is a letter or a number and
///   replaced by `-` otherwise, then split on Characters equal to `-` with
///   empty pieces dropped, joined with `-` and cut to 40 Characters. Each
///   step re-reads the clusters of the text it was given, as Swift's String
///   did, so a mark after a replaced character joins the new `-`.
pub fn file_name(standardized_path: &str) -> String {
    let hash: String = sha256::digest(standardized_path.as_bytes())
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect();

    let folder = text::last_path_component(standardized_path);
    // URL.lastPathComponent drops one byte order mark at the start of the
    // component (measured on macOS 27.2: "\u{FEFF}\u{FEFF}a" gives
    // "\u{FEFF}a"), and Swift slugged what it returned.
    let folder = folder.strip_prefix('\u{FEFF}').unwrap_or(folder);
    let lowered = text::lowercase_scalars(folder);
    let mapped: String = lowered
        .graphemes(true)
        .map(|cluster| {
            if text::is_letter_or_number(cluster) {
                cluster
            } else {
                "-"
            }
        })
        .collect();
    let clusters: Vec<&str> = mapped.graphemes(true).collect();
    let joined = clusters
        .split(|cluster| *cluster == "-")
        .filter(|piece| !piece.is_empty())
        .map(<[&str]>::concat)
        .collect::<Vec<_>>()
        .join("-");
    let slug = text::grapheme_prefix(&joined, 40);

    if slug.is_empty() {
        format!("{hash}.jsonl")
    } else {
        format!("{slug}-{hash}.jsonl")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";

    fn entry(text: &str, date_seconds: f64) -> TranscriptEntry {
        TranscriptEntry {
            id: ID.to_owned(),
            kind: TranscriptKind::User,
            text: text.to_owned(),
            date_seconds,
        }
    }

    #[test]
    fn a_line_reads_back_as_its_entry() {
        let written = entry("say \"hi\"\n/ 项目", 1_761_700_000.123_456);
        let line = entry_line(&written).unwrap();
        assert!(line.ends_with('\n'));
        assert_eq!(
            decode_line(line.trim_end_matches('\n').as_bytes()),
            Some(written)
        );
    }

    #[test]
    fn a_non_finite_date_is_refused() {
        assert!(entry_line(&entry("x", f64::NAN)).is_err());
        assert!(entry_line(&entry("x", f64::INFINITY)).is_err());
    }

    #[test]
    fn uuid_strings_like_foundation() {
        assert_eq!(uuid_string(&ID.to_lowercase()).as_deref(), Some(ID));
        assert_eq!(uuid_string(&format!("{ID}\0junk")).as_deref(), Some(ID));
        for refused in [
            "",
            "3F2504E04F8941D39A0C0305E82C3301",
            "{3F2504E0-4F89-41D3-9A0C-0305E82C3301}",
            " 3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "3F2504E0-4F89-41D3-9A0C-0305E82C330",
            "3F2504E0-4F89-41D3-9A0C-0305E82C33011",
            "3F2504E0+4F89-41D3-9A0C-0305E82C3301",
            "3F2504E0-4F89-41D3-9A0C-0305E82C330G",
            "３F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "3F2504E0\0-4F89-41D3-9A0C-0305E82C3301",
        ] {
            assert_eq!(uuid_string(refused), None, "{refused:?}");
        }
    }

    #[test]
    fn load_tail_compacts_past_2000() {
        let mut file = String::new();
        for at in 1..=MAX_STORED_ENTRIES + 50 {
            file += &entry_line(&entry(&format!("m{at}"), 1_761_700_000.0)).unwrap();
        }
        let load = load_tail(file.as_bytes(), 5);
        let texts: Vec<&str> = load.entries.iter().map(|e| e.text.as_str()).collect();
        assert_eq!(texts, ["m2046", "m2047", "m2048", "m2049", "m2050"]);
        let rewrite = load.rewrite.unwrap();
        assert_eq!(rewrite.lines().count(), MAX_STORED_ENTRIES);
        assert!(rewrite.starts_with(&entry_line(&entry("m51", 1_761_700_000.0)).unwrap()));
        assert!(rewrite.ends_with(&entry_line(&entry("m2050", 1_761_700_000.0)).unwrap()));

        // At the limit nothing is rewritten.
        let at_limit: String = (0..MAX_STORED_ENTRIES)
            .map(|_| entry_line(&entry("x", 0.0)).unwrap())
            .collect();
        assert_eq!(load_tail(at_limit.as_bytes(), 1).rewrite, None);
    }

    #[test]
    fn a_rewrite_writes_dates_as_a_date_holds_them() {
        // Measured: Date(timeIntervalSince1970: 0.1).timeIntervalSince1970
        // is 0.10000002384185791, and JSONEncoder wrote that.
        assert_eq!(as_a_date_holds(0.1), 0.100_000_023_841_857_91);
        assert_eq!(as_a_date_holds(5e-324), 0.0);
        assert_eq!(
            as_a_date_holds(1_761_700_000.123_456),
            1_761_700_000.123_456
        );
        let mut file = String::new();
        for _ in 0..=MAX_STORED_ENTRIES {
            file += &entry_line(&entry("x", 0.1)).unwrap();
        }
        let load = load_tail(file.as_bytes(), 1);
        // The entry keeps the seconds read; the rewrite holds the Date's.
        assert_eq!(load.entries[0].date_seconds, 0.1);
        assert!(load
            .rewrite
            .unwrap()
            .ends_with("\"text\":\"x\",\"date\":0.10000002384185791}\n"));
    }

    #[test]
    fn kinds_round_trip_by_name() {
        for kind in [
            TranscriptKind::User,
            TranscriptKind::Assistant,
            TranscriptKind::Tool,
            TranscriptKind::System,
            TranscriptKind::Error,
        ] {
            assert_eq!(TranscriptKind::from_name(kind.name()), Some(kind));
        }
        assert_eq!(TranscriptKind::from_name("User"), None);
    }

    #[test]
    fn one_leading_byte_order_mark_is_not_part_of_the_folder_name() {
        let hash = |path: &str| {
            file_name(path)
                .rsplit('-')
                .next()
                .unwrap_or_default()
                .to_owned()
        };
        assert_eq!(
            file_name("/x/\u{FEFF}a"),
            format!("a-{}", hash("/x/\u{FEFF}a"))
        );
        assert!(file_name("/x/\u{FEFF}\u{FEFF}a").starts_with("a-"));
        assert!(file_name("/x/\u{FEFF}\u{E33}").starts_with("\u{E33}-"));
        assert!(file_name("/x/a\u{FEFF}b").starts_with("a-b-"));
    }

    #[test]
    fn a_mark_after_a_replaced_character_joins_the_hyphen() {
        // "\n" becomes "-", and the alphabetic combining mark that stood
        // alone after it joins that hyphen into a Character that is not
        // "-", so it does not split.
        let name = file_name("/x/a\n\u{345}b");
        assert!(name.starts_with("a-\u{345}b-"), "{name:?}");
    }
}
