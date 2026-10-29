//! How the claude CLI's stdout bytes become lines (HK-052, HK-053).
//!
//! The platform reads the pipe in whatever chunks the OS hands it and feeds
//! them here in order. Splitting per chunk would hand half a JSON object to
//! the parser, so the bytes after the last newline wait for the next chunk
//! and come out only when the stream ends.

/// 16 MiB: an unterminated line that grows past this is dropped instead of
/// growing the buffer without bound (HK-053).
pub const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

/// The stdout bytes of one launch that no newline has finished yet.
#[derive(Debug)]
pub struct LineBuffer {
    pending: Vec<u8>,
    limit: usize,
}

impl Default for LineBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl LineBuffer {
    /// A buffer that drops a tail past [`MAX_LINE_BYTES`].
    pub fn new() -> Self {
        Self::with_limit(MAX_LINE_BYTES)
    }

    /// A buffer with another limit, so tests can show the guard on a few
    /// bytes.
    pub fn with_limit(limit: usize) -> Self {
        LineBuffer {
            pending: Vec::new(),
            limit,
        }
    }

    /// Appends `chunk` and returns every line it finishes, in order. Lines
    /// split on the byte 0x0A only: a carriage return stays part of its
    /// line (the parser reads it as JSON whitespace), and an empty line is
    /// dropped. Afterwards a tail longer than the limit (strictly) is
    /// dropped and its memory released; whatever of that line arrives later
    /// becomes a garbage line of its own, which the parser ignores (HK-053).
    pub fn ingest(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        // Only the new bytes can hold a newline: the tail never does.
        let searched_from = self.pending.len();
        self.pending.extend_from_slice(chunk);
        let mut lines = Vec::new();
        let mut start = 0;
        for (offset, byte) in self.pending[searched_from..].iter().enumerate() {
            if *byte == b'\n' {
                let end = searched_from + offset;
                if end > start {
                    lines.push(self.pending[start..end].to_vec());
                }
                start = end + 1;
            }
        }
        // One drain per chunk, so a long tail is never copied per line.
        self.pending.drain(..start);
        if self.pending.len() > self.limit {
            self.pending = Vec::new();
        }
        lines
    }

    /// The buffered tail once the stream has ended, or `None` when nothing
    /// is buffered. Empties the buffer, so a second flush gives `None`.
    pub fn flush(&mut self) -> Option<Vec<u8>> {
        if self.pending.is_empty() {
            return None;
        }
        Some(std::mem::take(&mut self.pending))
    }

    /// How many bytes wait for a newline.
    pub fn buffered_len(&self) -> usize {
        self.pending.len()
    }

    /// The memory held for them, so the guard's release can be shown.
    pub fn buffered_capacity(&self) -> usize {
        self.pending.capacity()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness::claude::event::ClaudeEvent;
    use crate::harness::claude::parse::events_from_line;

    const MIB: usize = 1024 * 1024;

    #[test]
    fn a_runaway_line_is_discarded_without_growing() {
        let mut buffer = LineBuffer::new();
        let chunk = vec![b'x'; MIB];
        for _ in 0..16 {
            assert!(buffer.ingest(&chunk).is_empty());
        }
        assert_eq!(buffer.buffered_len(), 16 * MIB, "exactly 16 MiB is kept");
        assert!(buffer.ingest(&chunk).is_empty());
        assert_eq!(buffer.buffered_len(), 0);
        assert!(buffer.buffered_capacity() <= MIB, "the memory is released");

        // The buffer never holds more than the limit plus one chunk.
        for _ in 0..40 {
            assert!(buffer.ingest(&chunk).is_empty());
            assert!(buffer.buffered_capacity() <= 17 * MIB + MIB);
        }

        let init = br#"{"type":"system","subtype":"init","session_id":"s","model":"m"}"#;
        let mut tail = b"xxx\n".to_vec();
        tail.extend_from_slice(init);
        tail.push(b'\n');
        let lines = buffer.ingest(&tail);
        assert_eq!(lines.len(), 2);
        assert!(lines[0].iter().all(|byte| *byte == b'x'));
        assert_eq!(lines[1], init);
        let events: Vec<ClaudeEvent> = lines.iter().flat_map(|l| events_from_line(l)).collect();
        assert_eq!(
            events,
            [ClaudeEvent::Ready {
                session_id: "s".into(),
                model: "m".into()
            }]
        );
    }

    #[test]
    fn the_limit_is_strict() {
        let mut kept = LineBuffer::with_limit(4);
        assert!(kept.ingest(b"abcd").is_empty());
        assert_eq!(kept.flush(), Some(b"abcd".to_vec()));

        let mut dropped = LineBuffer::with_limit(4);
        assert!(dropped.ingest(b"abcde").is_empty());
        assert_eq!(dropped.flush(), None);

        // Complete lines are never subject to the limit, only the tail.
        let mut long_lines = LineBuffer::with_limit(4);
        assert_eq!(long_lines.ingest(b"abcdefgh\nab"), [b"abcdefgh".to_vec()]);
        assert_eq!(long_lines.flush(), Some(b"ab".to_vec()));
    }

    #[test]
    fn a_flush_empties_the_buffer() {
        let mut buffer = LineBuffer::new();
        assert_eq!(buffer.flush(), None);
        assert!(buffer.ingest(b"half").is_empty());
        assert_eq!(buffer.flush(), Some(b"half".to_vec()));
        assert_eq!(buffer.flush(), None);
        assert_eq!(buffer.ingest(b"line\n"), [b"line".to_vec()]);
    }
}
