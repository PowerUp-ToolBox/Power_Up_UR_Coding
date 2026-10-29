//! The text safety rules of remote mode (DESIGN v1.4, v1.5, v2.14): what
//! happens to dictated text before an injector types it into a session
//! that runs elsewhere, and to cmux's output before the person reads it.
//!
//! A line break typed into a terminal is Enter, so every break is flattened
//! before any delivery route (HK-198), and `cmux send` reads backslash-n,
//! -r and -t as Enter and Tab, so cmux text is split into sends that defuse
//! them (HK-199 to HK-201). `cmux list-workspaces` output is parsed into
//! rows (HK-202, HK-203, HK-205), and a failed cmux command is condensed
//! and classified into one friendly message (HK-206, HK-207).
//!
//! The platform keeps the injector: it runs cmux (the `--` separator, the
//! pauses between sends, the deadlines, the socket password), posts the
//! keystrokes and chooses the route. These functions take strings and
//! values and return strings and values.
//!
//! The rules are Swift's `String` rules, as the macOS app applied them:
//! flattening works on scalars, everything else on `Character`s (extended
//! grapheme clusters, [`text`]), and the trims are Foundation's
//! `whitespacesAndNewlines` ([`text::trim`]) or `whitespaces`
//! ([`text::trim_whitespaces`]). Two Apple behaviours are reproduced by
//! hand and were measured on macOS 27.2: `UUID(uuidString:)` and the
//! Emoji_Presentation property of the Dingbats block.

use unicode_segmentation::UnicodeSegmentation;

use crate::text;

/// The scalars that are a line or paragraph break: LF, CR, U+2028 LINE
/// SEPARATOR and U+2029 PARAGRAPH SEPARATOR. Tab, VT, FF and NEL are not.
const LINE_BREAKS: [char; 4] = ['\n', '\r', '\u{2028}', '\u{2029}'];

/// Every line break becomes a space and a run of breaks becomes one space
/// (CRLF, a blank line), so nothing the target terminal would read as Enter
/// survives inside the text (HK-198). It works on scalars: a break that a
/// combining mark follows is flattened too, and no other text changes
/// (spaces are not collapsed, nothing is trimmed).
pub fn flatten_line_breaks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut previous_was_break = false;
    for scalar in text.chars() {
        if LINE_BREAKS.contains(&scalar) {
            if !previous_was_break {
                out.push(' ');
            }
            previous_was_break = true;
        } else {
            previous_was_break = false;
            out.push(scalar);
        }
    }
    out
}

/// The most splits [`escape_safe_segments`] makes, so at most 13 sends
/// (HK-200): pathological text must not spawn a cmux process per escape.
pub const MAX_SEND_SPLITS: usize = 12;

/// The text as `cmux send` segments that cmux cannot reinterpret
/// (HK-199 to HK-201). cmux reads the two characters backslash-n, -r and -t
/// as Enter and Tab, but delivers a backslash that ends a send literally, so
/// the text is split right after each backslash that an `n`, `r` or `t`
/// follows. Line breaks are flattened first ([`flatten_line_breaks`]), so
/// the rule is safe on its own.
///
/// Characters are compared whole: a backslash or an `n` that a combining
/// mark extends, or a backslash a prepended scalar joins, is a different
/// character and no escape. Past [`MAX_SEND_SPLITS`] splits the rest goes
/// in the last segment and cmux's reading is accepted. Ordinary text is one
/// segment, empty text none, and the segments are never empty and always
/// join to the flattened text.
pub fn escape_safe_segments(text: &str) -> Vec<String> {
    let text = flatten_line_breaks(text);
    let clusters: Vec<&str> = text.graphemes(true).collect();
    let mut segments = Vec::new();
    let mut current = String::new();
    for (index, cluster) in clusters.iter().enumerate() {
        current.push_str(cluster);
        if *cluster != "\\" {
            continue;
        }
        let escapes = clusters
            .get(index + 1)
            .is_some_and(|next| matches!(*next, "n" | "r" | "t"));
        if escapes && segments.len() < MAX_SEND_SPLITS {
            segments.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        segments.push(current);
    }
    segments
}

/// One row of `cmux list-workspaces`: the ref the injector targets, the
/// title shown in pickers, and whether cmux has it selected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmuxWorkspace {
    /// `workspace:N`, or a bare UUID (`--id-format uuids`).
    pub reference: String,
    /// The rest of the row, without its activity glyph ([`strip_status_glyph`]).
    pub title: String,
    pub selected: bool,
}

/// The trailing selection tag.
const SELECTED_TAG: &str = "[selected]";

/// The short ref's prefix.
const WORKSPACE_PREFIX: &str = "workspace:";

/// Parses `cmux list-workspaces` output (run with CMUX_QUIET=1) into rows
/// (HK-202, HK-203). Lines are split on the LF character; a CR LF pair is
/// one other character, so CRLF output (which cmux on macOS never prints)
/// stays one line. Each line is trimmed (`whitespacesAndNewlines`); a blank
/// line and the legacy-alias notice (`cmux:`) are skipped.
///
/// A leading `*` selects the row and is dropped, then a trailing
/// `[selected]` selects it and is dropped (one, so a title that itself ends
/// in the tag keeps its literal); both trims after a marker are
/// `whitespaces`. The first piece before a space is the ref, kept only when
/// it is `workspace:` plus at least one character or a bare UUID; any other
/// line is skipped, never guessed. The rest, trimmed, without one activity
/// glyph, is the title. When several rows end up selected and a star row
/// exists, the star rows win and every other row is demoted.
pub fn parse_workspaces(output: &str) -> Vec<CmuxWorkspace> {
    let mut rows: Vec<CmuxWorkspace> = Vec::new();
    let mut star_rows: Vec<usize> = Vec::new();
    for raw_line in split_on_line_feeds(output) {
        let mut line = text::trim(raw_line);
        if line.is_empty() || text::starts_with_clusters(line, "cmux:") {
            continue;
        }
        let mut selected = false;
        let mut had_star = false;
        if let Some(rest) = strip_prefix_clusters(line, "*") {
            selected = true;
            had_star = true;
            line = text::trim_whitespaces(rest);
        }
        if let Some(rest) = strip_suffix_clusters(line, SELECTED_TAG) {
            selected = true;
            line = text::trim_whitespaces(rest);
        }
        let Some((reference, remainder)) = text::split_once_on_space(line) else {
            continue;
        };
        if !is_workspace_reference(reference) {
            continue;
        }
        let title = strip_status_glyph(text::trim_whitespaces(remainder));
        if had_star {
            star_rows.push(rows.len());
        }
        rows.push(CmuxWorkspace {
            reference: reference.to_owned(),
            title: title.to_owned(),
            selected,
        });
    }
    if rows.iter().filter(|row| row.selected).count() > 1 && !star_rows.is_empty() {
        for (index, row) in rows.iter_mut().enumerate() {
            if !star_rows.contains(&index) {
                row.selected = false;
            }
        }
    }
    rows
}

/// Swift's `split(separator: "\n", omittingEmptySubsequences: false)`: the
/// pieces between clusters equal to LF. A CR LF pair is one cluster that is
/// not LF, so it never separates.
fn split_on_line_feeds(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (at, cluster) in text.grapheme_indices(true) {
        if cluster == "\n" {
            lines.extend(text.get(start..at));
            start = at + cluster.len();
        }
    }
    lines.extend(text.get(start..));
    lines
}

/// The text after `prefix` when its first clusters are `prefix`'s
/// (`hasPrefix` then `dropFirst(prefix.count)`).
fn strip_prefix_clusters<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    if text::starts_with_clusters(text, prefix) {
        text.strip_prefix(prefix)
    } else {
        None
    }
}

/// The text before `suffix` when its last clusters are `suffix`'s
/// (`hasSuffix` then `dropLast(suffix.count)`).
fn strip_suffix_clusters<'a>(text: &'a str, suffix: &str) -> Option<&'a str> {
    if text::ends_with_clusters(text, suffix) {
        text.strip_suffix(suffix)
    } else {
        None
    }
}

/// `workspace:` and at least one more character (the rest is not checked,
/// so `workspace:abc` is a ref), or a bare UUID (HK-203). The prefix is
/// case-sensitive.
fn is_workspace_reference(token: &str) -> bool {
    if text::starts_with_clusters(token, WORKSPACE_PREFIX) {
        return text::grapheme_count(token) > text::grapheme_count(WORKSPACE_PREFIX);
    }
    is_uuid(token)
}

/// Foundation's `UUID(uuidString:)`: the canonical 8-4-4-4-12 form of
/// ASCII hex digits in either case, nothing around it (no braces, no
/// spaces). Foundation reads the token as a C string, so it stops at the
/// first NUL: a valid UUID that a NUL and more text follow is accepted
/// (measured on macOS 27.2).
fn is_uuid(token: &str) -> bool {
    let c_string = token.split('\0').next().unwrap_or_default();
    c_string.len() == 36
        && c_string.bytes().enumerate().all(|(at, byte)| {
            if matches!(at, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

/// The Dingbats scalars with emoji presentation, the only ones in the
/// Braille and Dingbats blocks (`Unicode.Scalar.Properties
/// .isEmojiPresentation`, every scalar of U+2700 to U+28FF listed on macOS
/// 27.2; Unicode's Emoji_Presentation).
const DINGBAT_EMOJI_PRESENTATION: [char; 15] = [
    '\u{2705}', '\u{270A}', '\u{270B}', '\u{2728}', '\u{274C}', '\u{274E}', '\u{2753}', '\u{2754}',
    '\u{2755}', '\u{2757}', '\u{2795}', '\u{2796}', '\u{2797}', '\u{27B0}', '\u{27BF}',
];

/// The title without the activity glyph cmux prints before it (HK-205): a
/// first character that is one scalar of the Braille Patterns block
/// (U+2800 to U+28FF, the spinner frames) or the Dingbats block (U+2700 to
/// U+27BF: ✳ ✓ ✗) without emoji presentation is dropped and the rest
/// trimmed (`whitespaces`). Anything else is returned verbatim: an emoji
/// (✅, or a glyph with VS16, a combining mark or a ZWJ, which is two
/// scalars), the `…` of a truncated path, a glyph that is not first.
pub fn strip_status_glyph(title: &str) -> &str {
    let Some(first) = title.graphemes(true).next() else {
        return title;
    };
    if !is_status_glyph(first) {
        return title;
    }
    text::trim_whitespaces(title.get(first.len()..).unwrap_or_default())
}

fn is_status_glyph(cluster: &str) -> bool {
    let mut scalars = cluster.chars();
    let (Some(scalar), None) = (scalars.next(), scalars.next()) else {
        return false;
    };
    !DINGBAT_EMOJI_PRESENTATION.contains(&scalar)
        && (('\u{2800}'..='\u{28FF}').contains(&scalar)
            || ('\u{2700}'..='\u{27BF}').contains(&scalar))
}

/// cmux output as one short line of at most `max_chars` characters
/// (HK-206, HK-173): [`text::condense`], which flattens CR, LF and tab,
/// collapses the spaces and cuts past the limit with `…`, counting and
/// cutting grapheme clusters. Every text is longer than a negative limit,
/// so there it is cut to its first character and `…` (only `…` for empty
/// text), as Swift's `condense(_:maxChars:)` did with an `Int`.
pub fn condense(text: &str, max_chars: i64) -> String {
    if max_chars >= 0 {
        return text::condense(text, usize::try_from(max_chars).unwrap_or(usize::MAX));
    }
    let collapsed = text::condense(text, usize::MAX);
    let mut cut = text::grapheme_prefix(&collapsed, 1).to_owned();
    cut.push('…');
    cut
}

/// How a cmux command ended, as the platform's process runner reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    /// The exit status (the macOS app reports -1 when it could not tell).
    pub status: i64,
    pub standard_output: String,
    pub standard_error: String,
    pub timed_out: bool,
    /// The process could not be launched at all.
    pub spawn_failed: bool,
}

/// The longest detail a spawn failure shows.
const SPAWN_DETAIL_LIMIT: usize = 160;

/// The longest detail any other failure shows.
const DETAIL_LIMIT: usize = 200;

/// What cmux's `cmuxOnly` socket mode refusing PowerUp means, and the fix.
const SOCKET_REFUSAL: &str = "cmux refused the connection. In cmux, open Settings → Automation, set “Socket control mode” to Password (or Automation), then quit and reopen cmux. For Password mode, put the same password in PowerUp’s Remote settings.";

/// The friendly message for a failed cmux command that `action` names
/// (HK-207), the first that applies of: a spawn failure (its stderr
/// condensed to 160, never translated); a timeout (stderr ignored); then,
/// with the detail being stderr condensed to 200 or, when that is empty,
/// stdout condensed to 200, and lowercased scalar by scalar: "socket not
/// found" (cmux is not running, verified live with cmux 0.64.17); "socket",
/// "broken pipe" or "permission" (the socket-mode refusal, which names no
/// action); no detail (the exit status); the detail. The keywords are
/// matched in the condensed detail as whole characters, so one past the cut
/// is not seen.
pub fn failure_message(action: &str, result: &CommandResult) -> String {
    if result.spawn_failed {
        let detail = text::condense(&result.standard_error, SPAWN_DETAIL_LIMIT);
        return if detail.is_empty() {
            format!("{action} failed to start.")
        } else {
            format!("{action} failed to start: {detail}")
        };
    }
    if result.timed_out {
        return format!("{action} timed out — is the cmux app running?");
    }
    let mut detail = text::condense(&result.standard_error, DETAIL_LIMIT);
    if detail.is_empty() {
        detail = text::condense(&result.standard_output, DETAIL_LIMIT);
    }
    let lowered = text::lowercase_scalars(&detail);
    if text::contains_clusters(&lowered, "socket not found") {
        return format!("{action} failed — cmux isn’t running. Open the cmux app, then try again.");
    }
    if ["socket", "broken pipe", "permission"]
        .iter()
        .any(|keyword| text::contains_clusters(&lowered, keyword))
    {
        return SOCKET_REFUSAL.to_owned();
    }
    if detail.is_empty() {
        return format!("{action} failed (exit {}).", result.status);
    }
    format!("{action} failed: {detail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_canonical_uuid_form_is_a_ref() {
        // Measured with Foundation's UUID(uuidString:) on macOS 27.2.
        let uuid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
        assert!(is_uuid(uuid));
        assert!(is_uuid(&uuid.to_lowercase()));
        assert!(is_uuid(&format!("{uuid}\0")));
        assert!(is_uuid(&format!("{uuid}\0xyz")));
        for refused in [
            format!("{{{uuid}}}"),
            uuid.replace('-', ""),
            format!(" {uuid}"),
            format!("{uuid} "),
            format!("\0{uuid}"),
            format!("{uuid}\u{301}"),
            "3F2504E0-4F89-11D3-9A0C-0305E82C330G".to_owned(),
            "3F2504E0-4F89-11D3-9A0C-0305E82C330".to_owned(),
            "3F2504E04-F89-11D3-9A0C-0305E82C3301".to_owned(),
            "+F2504E0-4F89-11D3-9A0C-0305E82C3301".to_owned(),
            "3F2504E0-+F89-11D3-9A0C-0305E82C3301".to_owned(),
            "0x2504E0-4F89-11D3-9A0C-0305E82C3301".to_owned(),
            "3F2504E0_4F89-11D3-9A0C-0305E82C3301".to_owned(),
            "３F2504E0-4F89-11D3-9A0C-0305E82C3301".to_owned(),
            String::new(),
        ] {
            assert!(!is_uuid(&refused), "{refused:?}");
        }
    }

    #[test]
    fn the_glyph_blocks_less_their_emoji_are_glyphs() {
        let glyphs = ('\u{2700}'..='\u{28FF}')
            .filter(|scalar| is_status_glyph(scalar.encode_utf8(&mut [0; 4])))
            .count();
        // Dingbats (U+2700 to U+27BF) and Braille (U+2800 to U+28FF); the
        // math and arrow blocks between them are no glyphs.
        assert_eq!(glyphs, 0xC0 + 0x100 - DINGBAT_EMOJI_PRESENTATION.len());
        for kept in ['\u{26FF}', '\u{27C0}', '\u{2900}', '\u{2026}', '\u{1F680}'] {
            assert!(!is_status_glyph(kept.encode_utf8(&mut [0; 4])), "{kept:?}");
        }
        assert!(!is_status_glyph("\u{2733}\u{FE0F}"));
        assert!(!is_status_glyph(""));
    }

    #[test]
    fn segments_are_whole_characters_up_to_the_cap() {
        assert_eq!(escape_safe_segments("a\\nb"), ["a\\", "nb"]);
        assert_eq!(escape_safe_segments("a\\\u{301}nb"), ["a\\\u{301}nb"]);
        assert!(escape_safe_segments("").is_empty());
        let many = "\\n".repeat(20);
        let segments = escape_safe_segments(&many);
        assert_eq!(segments.len(), MAX_SEND_SPLITS + 1);
        assert_eq!(segments.concat(), many);
    }

    #[test]
    fn odd_text_never_panics() {
        for odd in [
            "",
            "\0",
            "*",
            "[selected]",
            "*[selected]",
            "\u{301}",
            "\r\n\r\n",
            "\u{2733}",
            "workspace:",
            "\u{600}",
            "🇯🇵🇺",
        ] {
            let _ = flatten_line_breaks(odd);
            let _ = escape_safe_segments(odd);
            let _ = parse_workspaces(odd);
            let _ = strip_status_glyph(odd);
            for limit in [i64::MIN, -1, 0, 1, i64::MAX] {
                let _ = condense(odd, limit);
            }
            let result = CommandResult {
                status: i64::MIN,
                standard_output: odd.to_owned(),
                standard_error: odd.to_owned(),
                timed_out: false,
                spawn_failed: false,
            };
            let _ = failure_message(odd, &result);
        }
    }
}
