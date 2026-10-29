//! The transcript's JSON Lines rules (slice 2.5): the line an entry is
//! written as, how a whole file loads, the per-project file name and the
//! two limits. The file stays with the app: these functions take and
//! return bytes and strings (DESIGN v2.14 A).

use powerup_core::transcript::{
    self, TranscriptEntry, TranscriptKind, TranscriptLoad, DEFAULT_RESTORE_COUNT,
    MAX_STORED_ENTRIES,
};

use crate::{contain, CoreBridgeError};

/// Who an entry is from (also what the session machine appends).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CoreTranscriptKind {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

/// One transcript entry: the id as `uuidString` spells it, the date as
/// seconds since 1970.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreTranscriptEntry {
    pub id: String,
    pub kind: CoreTranscriptKind,
    pub text: String,
    pub date_seconds: f64,
}

/// What loading a transcript file found: the entries asked for, oldest
/// first, and the bytes to replace the file with when it outgrew the limit.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreTranscriptLoad {
    pub entries: Vec<CoreTranscriptEntry>,
    pub rewrite: Option<Vec<u8>>,
}

/// How many entries a file keeps, and how many a restore brings back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CoreTranscriptLimits {
    pub max_stored_entries: u32,
    pub default_restore_count: u32,
}

impl From<CoreTranscriptKind> for TranscriptKind {
    fn from(kind: CoreTranscriptKind) -> Self {
        match kind {
            CoreTranscriptKind::User => TranscriptKind::User,
            CoreTranscriptKind::Assistant => TranscriptKind::Assistant,
            CoreTranscriptKind::Tool => TranscriptKind::Tool,
            CoreTranscriptKind::System => TranscriptKind::System,
            CoreTranscriptKind::Error => TranscriptKind::Error,
        }
    }
}

impl From<TranscriptKind> for CoreTranscriptKind {
    fn from(kind: TranscriptKind) -> Self {
        match kind {
            TranscriptKind::User => CoreTranscriptKind::User,
            TranscriptKind::Assistant => CoreTranscriptKind::Assistant,
            TranscriptKind::Tool => CoreTranscriptKind::Tool,
            TranscriptKind::System => CoreTranscriptKind::System,
            TranscriptKind::Error => CoreTranscriptKind::Error,
        }
    }
}

impl From<CoreTranscriptEntry> for TranscriptEntry {
    fn from(entry: CoreTranscriptEntry) -> Self {
        TranscriptEntry {
            id: entry.id,
            kind: entry.kind.into(),
            text: entry.text,
            date_seconds: entry.date_seconds,
        }
    }
}

impl From<TranscriptEntry> for CoreTranscriptEntry {
    fn from(entry: TranscriptEntry) -> Self {
        CoreTranscriptEntry {
            id: entry.id,
            kind: entry.kind.into(),
            text: entry.text,
            date_seconds: entry.date_seconds,
        }
    }
}

impl From<TranscriptLoad> for CoreTranscriptLoad {
    fn from(load: TranscriptLoad) -> Self {
        CoreTranscriptLoad {
            entries: load.entries.into_iter().map(Into::into).collect(),
            rewrite: load.rewrite.map(String::into_bytes),
        }
    }
}

/// The bytes one entry appends to its file, LF included
/// (`transcript::entry_line`).
#[uniffi::export]
pub fn transcript_line(entry: CoreTranscriptEntry) -> Result<Vec<u8>, CoreBridgeError> {
    contain(|| transcript::entry_line(&entry.into()).map(String::into_bytes))
}

/// A whole transcript file's bytes loaded (`transcript::load_tail`): the
/// newest `max_entries` entries and, past the limit, the bytes to rewrite
/// the file with.
#[uniffi::export]
pub fn transcript_load(
    bytes: Vec<u8>,
    max_entries: u32,
) -> Result<CoreTranscriptLoad, CoreBridgeError> {
    contain(|| {
        let max_entries = usize::try_from(max_entries).unwrap_or(usize::MAX);
        Ok(transcript::load_tail(&bytes, max_entries).into())
    })
}

/// The file name of the transcript for a standardized project path
/// (`transcript::file_name`).
#[uniffi::export]
pub fn transcript_file_name(standardized_path: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(transcript::file_name(&standardized_path)))
}

/// The two limits, so the app's constants are the core's.
#[uniffi::export]
pub fn transcript_limits() -> Result<CoreTranscriptLimits, CoreBridgeError> {
    let limit = |value: usize| u32::try_from(value).unwrap_or(u32::MAX);
    contain(|| {
        Ok(CoreTranscriptLimits {
            max_stored_entries: limit(MAX_STORED_ENTRIES),
            default_restore_count: limit(DEFAULT_RESTORE_COUNT),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(text: &str) -> CoreTranscriptEntry {
        CoreTranscriptEntry {
            id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301".into(),
            kind: CoreTranscriptKind::Assistant,
            text: text.into(),
            date_seconds: 1_761_700_000.5,
        }
    }

    #[test]
    fn a_line_loads_back_through_the_bridge() {
        let line = transcript_line(entry("a/b")).unwrap();
        assert_eq!(
            line,
            br#"{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","kind":"assistant","text":"a\/b","date":1761700000.5}
"#
        );
        let mut file = line.clone();
        file.extend_from_slice(b"garbage\n");
        file.extend(transcript_line(entry("second")).unwrap());
        let load = transcript_load(file, 200).unwrap();
        assert_eq!(load.entries, [entry("a/b"), entry("second")]);
        assert_eq!(load.rewrite, None);
        assert_eq!(transcript_load(line, 0).unwrap().entries, []);
    }

    #[test]
    fn an_overgrown_file_comes_back_with_its_rewrite() {
        let line = transcript_line(entry("x")).unwrap();
        let file = line.repeat(2001);
        let load = transcript_load(file, 3).unwrap();
        assert_eq!(load.entries.len(), 3);
        assert_eq!(load.rewrite, Some(line.repeat(2000)));
    }

    #[test]
    fn a_non_finite_date_is_an_error() {
        let mut bad = entry("x");
        bad.date_seconds = f64::NAN;
        assert!(matches!(
            transcript_line(bad),
            Err(CoreBridgeError::Failed { .. })
        ));
    }

    #[test]
    fn names_and_limits_are_the_cores() {
        assert_eq!(
            transcript_file_name("/tmp/work/api".into()).unwrap(),
            "api-ad9243f90664.jsonl"
        );
        assert_eq!(
            transcript_limits().unwrap(),
            CoreTranscriptLimits {
                max_stored_entries: 2000,
                default_restore_count: 200
            }
        );
    }
}
