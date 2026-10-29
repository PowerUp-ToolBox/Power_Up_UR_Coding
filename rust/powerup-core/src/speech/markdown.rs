//! The markdown stripping of [`super::spoken_reply`], one pass per
//! NSRegularExpression the Swift app ran (HK-214, HK-215), written by hand
//! with ICU's semantics for exactly those patterns: no regex crate matches
//! ICU's line starts.
//!
//! Each pass scans the text it is given from the left, as
//! `stringByReplacingMatches` does: at each position it tries the pattern,
//! and on a match emits the replacement and goes on after the match, else
//! keeps the scalar and moves one on. Matching works on scalars (ICU
//! matches code points); Characters never matter here. What each pattern
//! needs from ICU:
//!
//! - `\s` is the White_Space property, line breaks included, which is
//!   `char::is_whitespace` (every scalar compared on macOS 27.2). So a
//!   heading or quote marker's `\s` swallows the blank lines after it.
//! - `(?m)^` matches at the start of the text and after any scalar ICU's
//!   multi-line caret takes for a line end: U+000A to U+000D, U+0085,
//!   U+2028 and U+2029, but not between a CR and its LF; it is looked up
//!   in the text the pass was given, never in its output (measured with
//!   NSRegularExpression on macOS 27.2).
//! - A negated class (`[^*]`) matches every other scalar, line breaks
//!   included, and `[\s\S]` matches any scalar.
//! - The patterns' greedy runs need no backtracking search: each run is
//!   followed by a scalar its class excludes, so a shorter run never lets
//!   the rest match where the longest one did not.

/// A scalar after which ICU's multi-line `^` matches.
fn ends_a_line(scalar: char) -> bool {
    matches!(
        scalar,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// ICU's multi-line `^` at `at`: the start of the text, or right after a
/// line end, except between a CR and the LF after it, which end one line
/// together. A pass only asks where a scalar follows.
fn line_starts_at(text: &[char], at: usize) -> bool {
    let Some(before) = at.checked_sub(1) else {
        return true;
    };
    match (text.get(before), text.get(at)) {
        (Some('\r'), Some('\n')) => false,
        (Some(scalar), _) => ends_a_line(*scalar),
        (None, _) => false,
    }
}

/// Applies `matcher` at every position from the left: `Some((end,
/// replacement))` replaces `text[at..end]`, `None` keeps the scalar.
fn replace_all(
    text: &[char],
    mut matcher: impl FnMut(&[char], usize) -> Option<(usize, Vec<char>)>,
) -> Vec<char> {
    let mut out = Vec::with_capacity(text.len());
    let mut at = 0;
    while let Some(scalar) = text.get(at) {
        match matcher(text, at) {
            Some((end, replacement)) if end > at => {
                out.extend(replacement);
                at = end;
            }
            _ => {
                out.push(*scalar);
                at += 1;
            }
        }
    }
    out
}

/// Whether `text[at..]` begins with `wanted`.
fn starts_with(text: &[char], at: usize, wanted: &[char]) -> bool {
    text.get(at..).is_some_and(|rest| rest.starts_with(wanted))
}

/// The longest run from `at` whose scalars `keep` takes, as its end.
fn run_end(text: &[char], at: usize, keep: impl Fn(char) -> bool) -> usize {
    let mut end = at;
    while text.get(end).is_some_and(|scalar| keep(*scalar)) {
        end += 1;
    }
    end
}

/// The scalars `text[from..to]` (empty when out of range).
fn slice(text: &[char], from: usize, to: usize) -> Vec<char> {
    text.get(from..to).map(<[char]>::to_vec).unwrap_or_default()
}

const FENCE: [char; 3] = ['`', '`', '`'];

/// ```` ```[\s\S]*?``` ```` becomes `placeholder`: a fence runs to the
/// nearest closing fence, across lines; a fence nothing closes is no
/// fence, and nothing after it is either (HK-214).
pub(super) fn replace_fences(text: &[char], placeholder: char) -> Vec<char> {
    replace_all(text, |text, at| {
        if !starts_with(text, at, &FENCE) {
            return None;
        }
        let close = (at + FENCE.len()..text.len()).find(|from| starts_with(text, *from, &FENCE))?;
        Some((close + FENCE.len(), vec![placeholder]))
    })
}

/// `` `([^`]*)` `` becomes its content: inline code keeps its text, may
/// cross lines and may be empty; an unpaired backtick is left for
/// [`drop_stray_marks`].
pub(super) fn strip_inline_code(text: &[char]) -> Vec<char> {
    replace_all(text, |text, at| {
        if text.get(at) != Some(&'`') {
            return None;
        }
        let close = run_end(text, at + 1, |scalar| scalar != '`');
        (text.get(close) == Some(&'`')).then(|| (close + 1, slice(text, at + 1, close)))
    })
}

/// `!?\[([^\]]*)\]\([^)]*\)` becomes the bracket text: a link or an image
/// keeps its text or alt text. The text ends at the first `]`, the target
/// at the first `)`, so a target holding `)` leaves its tail behind.
pub(super) fn strip_links(text: &[char]) -> Vec<char> {
    replace_all(text, |text, at| {
        let open = match text.get(at) {
            Some('!') if text.get(at + 1) == Some(&'[') => at + 1,
            Some('[') => at,
            _ => return None,
        };
        let label_end = run_end(text, open + 1, |scalar| scalar != ']');
        if text.get(label_end) != Some(&']') || text.get(label_end + 1) != Some(&'(') {
            return None;
        }
        let target_end = run_end(text, label_end + 2, |scalar| scalar != ')');
        (text.get(target_end) == Some(&')'))
            .then(|| (target_end + 1, slice(text, open + 1, label_end)))
    })
}

/// A line-start marker `^\s{0,3}M\s<rest>` goes, where `marker` is the run
/// of marker scalars from `at` it accepts (its end, or `None`) and the
/// trailing `\s` is one or more (`at_least_one`) or at most one.
fn strip_line_markers(
    text: &[char],
    marker: impl Fn(&[char], usize) -> Option<usize>,
    trailing: Trailing,
) -> Vec<char> {
    replace_all(text, |text, at| {
        if !line_starts_at(text, at) {
            return None;
        }
        // `\s{0,3}` looks at four scalars at most, as ICU does: an unbounded
        // run would rescan a run of blank lines from each of its line
        // starts, quadratic in its length.
        let indent = text
            .get(at..)
            .unwrap_or_default()
            .iter()
            .take(4)
            .take_while(|scalar| scalar.is_whitespace())
            .count();
        if indent > 3 {
            return None;
        }
        let indent_end = at + indent;
        let marker_end = marker(text, indent_end)?;
        let end = match trailing {
            Trailing::OneOrMore => {
                let end = run_end(text, marker_end, char::is_whitespace);
                (end > marker_end).then_some(end)?
            }
            Trailing::AtMostOne => {
                marker_end
                    + usize::from(
                        text.get(marker_end)
                            .is_some_and(|scalar| scalar.is_whitespace()),
                    )
            }
        };
        Some((end, Vec::new()))
    })
}

#[derive(Clone, Copy)]
enum Trailing {
    OneOrMore,
    AtMostOne,
}

/// `(?m)^\s{0,3}#{1,6}\s+` goes: a heading marker of one to six hashes
/// and the whitespace after it, line breaks included. Seven hashes are no
/// heading (the hashes go later, in [`drop_stray_marks`]).
pub(super) fn strip_headings(text: &[char]) -> Vec<char> {
    strip_line_markers(
        text,
        |text, from| {
            let end = run_end(text, from, |scalar| scalar == '#');
            (1..=6).contains(&(end - from)).then_some(end)
        },
        Trailing::OneOrMore,
    )
}

/// `(?m)^\s{0,3}>\s?` goes: a quote marker and at most one whitespace
/// scalar after it. The indent may be blank lines.
pub(super) fn strip_quotes(text: &[char]) -> Vec<char> {
    strip_line_markers(
        text,
        |text, from| (text.get(from) == Some(&'>')).then_some(from + 1),
        Trailing::AtMostOne,
    )
}

/// `(?m)^\s{0,3}[-*+]\s+` goes: a bullet and the whitespace after it. It
/// runs after the emphasis passes, so star bullets may already have paired
/// as italic markers (HK-215).
pub(super) fn strip_bullets(text: &[char]) -> Vec<char> {
    strip_line_markers(
        text,
        |text, from| {
            text.get(from)
                .is_some_and(|scalar| matches!(scalar, '-' | '*' | '+'))
                .then_some(from + 1)
        },
        Trailing::OneOrMore,
    )
}

/// `D([^d]+)D` becomes its content, where `D` is `delimiter` repeated
/// `width` times and `d` is `delimiter`: `**x**`, `*x*`, `__x__`, `_x_`
/// and `~~x~~` keep `x`, across lines.
pub(super) fn strip_emphasis(text: &[char], delimiter: char, width: usize) -> Vec<char> {
    let fence = vec![delimiter; width];
    replace_all(text, |text, at| {
        if !starts_with(text, at, &fence) {
            return None;
        }
        let content_end = run_end(text, at + width, |scalar| scalar != delimiter);
        (content_end > at + width && starts_with(text, content_end, &fence))
            .then(|| (content_end + width, slice(text, at + width, content_end)))
    })
}

/// `[#*_>`]` goes: every markdown mark the earlier passes left, anywhere
/// (`C#`, `a > b`, `snake_case`).
pub(super) fn drop_stray_marks(text: &[char]) -> Vec<char> {
    text.iter()
        .copied()
        .filter(|scalar| !matches!(scalar, '#' | '*' | '_' | '>' | '`'))
        .collect()
}

/// `\s+` becomes one space.
pub(super) fn collapse_whitespace(text: &[char]) -> Vec<char> {
    replace_all(text, |text, at| {
        let end = run_end(text, at, char::is_whitespace);
        (end > at).then(|| (end, vec![' ']))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(pass: impl Fn(&[char]) -> Vec<char>, text: &str) -> String {
        pass(&text.chars().collect::<Vec<_>>())
            .into_iter()
            .collect()
    }

    #[test]
    fn a_fence_runs_to_the_nearest_close_and_an_open_one_is_kept() {
        let fences = |text: &[char]| replace_fences(text, 'P');
        assert_eq!(run(fences, "a```x```b```y```c"), "aPbPc");
        assert_eq!(run(fences, "a ```x``` b ```open"), "a P b ```open");
        assert_eq!(run(fences, "``````"), "P");
        assert_eq!(run(fences, "````x```"), "P");
        assert_eq!(run(fences, "``"), "``");
        assert_eq!(run(fences, ""), "");
    }

    #[test]
    fn a_line_starts_after_every_icu_line_end() {
        for end in [
            '\n', '\u{0B}', '\u{0C}', '\r', '\u{85}', '\u{2028}', '\u{2029}',
        ] {
            assert_eq!(
                run(strip_headings, &format!("x{end}# y")),
                format!("x{end}y"),
                "{end:?}"
            );
        }
        // Not between CR and LF: the marker's indent would take the LF.
        assert_eq!(run(strip_headings, "x\r\n# y"), "x\r\ny");
        assert_eq!(run(strip_bullets, "a\r\n\r\n- b"), "a\r\nb");
        assert_eq!(run(strip_headings, "x\u{1C}# y"), "x\u{1C}# y");
        assert_eq!(run(strip_headings, "x # y"), "x # y");
    }

    #[test]
    fn line_starts_are_read_in_the_text_a_pass_was_given() {
        // The second marker starts a line of the input although the first
        // match swallowed the break before it.
        assert_eq!(run(strip_headings, "#\n# x"), "x");
        assert_eq!(run(strip_quotes, "> \n> x"), "\nx");
    }

    #[test]
    fn markers_take_at_most_three_indent_scalars() {
        assert_eq!(run(strip_bullets, "   - a"), "a");
        assert_eq!(run(strip_bullets, "    - a"), "    - a");
        assert_eq!(run(strip_quotes, "\n\n> x"), "x");
        assert_eq!(run(strip_quotes, "\n\n\n\n> x"), "\nx");
        assert_eq!(run(strip_headings, "####### x"), "####### x");
        assert_eq!(run(strip_headings, "#x"), "#x");
        assert_eq!(run(strip_bullets, "-x"), "-x");
        assert_eq!(run(strip_quotes, ">x"), "x");
        assert_eq!(run(strip_quotes, ">  x"), " x");
    }

    #[test]
    fn emphasis_needs_content_and_a_closing_delimiter() {
        let bold = |text: &[char]| strip_emphasis(text, '*', 2);
        let italic = |text: &[char]| strip_emphasis(text, '*', 1);
        assert_eq!(run(bold, "***a**"), "*a");
        assert_eq!(run(bold, "****"), "****");
        assert_eq!(run(italic, "* a\n* b\n* c"), " a\n b\n* c");
        assert_eq!(run(italic, "**"), "**");
    }

    #[test]
    fn links_keep_their_text_or_nothing_matches() {
        assert_eq!(run(strip_links, "![a](b) [c](d)"), "a c");
        assert_eq!(run(strip_links, "!x[a](b)"), "!xa");
        assert_eq!(run(strip_links, "![a](b"), "![a](b");
        assert_eq!(run(strip_links, "[](x)"), "");
        assert_eq!(run(strip_links, "[a]\n(b)"), "[a]\n(b)");
    }

    #[test]
    fn a_line_marker_looks_at_four_scalars_of_indent_at_most() {
        assert_eq!(run(strip_headings, "   # x"), "x");
        assert_eq!(run(strip_headings, "    # x"), "    # x");
        // Line breaks are indent too (NSRegularExpression on macOS 27.2).
        assert_eq!(run(strip_quotes, "\n\n\n> x"), "x");
        assert_eq!(run(strip_bullets, " \t\n- x"), "x");
        assert_eq!(run(strip_bullets, "\n\n\n\n- x"), "\nx");
    }

    #[test]
    fn a_long_run_of_blank_lines_is_one_pass() {
        // Every line break in the run starts a line; a pass that scanned
        // the whole run from each took minutes here (ICU's `\s{0,3}` stops
        // after four scalars).
        let blank_lines = |run: &str| -> Vec<char> {
            let mut text = vec!['a'];
            text.extend(run.chars().cycle().take(200_000));
            text.push('b');
            text
        };
        let started = std::time::Instant::now();
        for text in [blank_lines("\n"), blank_lines(" \n")] {
            for pass in [strip_headings, strip_quotes, strip_bullets] {
                assert_eq!(pass(&text), text);
            }
        }
        let elapsed = started.elapsed();
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "six passes over 200,000 blank lines took {elapsed:?}"
        );
    }
}
