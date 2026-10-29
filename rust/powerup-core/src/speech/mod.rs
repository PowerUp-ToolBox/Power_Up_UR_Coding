//! The speech text rules (DESIGN v1.2 A, v1.12, v2.14; ADR 0011): what a
//! reply sounds like once markdown is gone, which language its phrases and
//! voice are chosen for, and the pure rules of spoken summaries.
//!
//! A reply's fenced code becomes a placeholder before anything else, so
//! the identifiers inside cannot decide the language (HK-214); the language
//! is decided once, on that text ([`dominant_language`], HK-211 to
//! HK-213); the markdown is stripped in a fixed order (HK-215); and a long
//! result is cut at a sentence ender, full-width CJK ones included, with a
//! localized note (HK-216).
//!
//! The platform keeps the engines and the voices: which installed voice
//! serves a language (simplified or traditional Chinese among them), the
//! synthesizer, audio routing, and the summarizer process. These functions
//! take strings and return strings and decisions.
//!
//! The rules are Swift's, as the macOS app applied them: lengths and cuts
//! count `Character`s (extended grapheme clusters, [`text`], HK-173), the
//! trims are Foundation's `whitespacesAndNewlines` ([`text::trim`]), and
//! the markdown passes reproduce NSRegularExpression's semantics for the
//! patterns the app used (`markdown`). The statistical half of the
//! language decision is the one rule two libraries carry out: whatlang
//! here, held to the text's letters and function words (`evidence`,
//! HK-425), NLLanguageRecognizer in the Swift app.

mod evidence;
mod language;
mod markdown;
mod summary;

use unicode_segmentation::UnicodeSegmentation;

use crate::text;

pub use language::{
    cjk_script_language, dominant_language, CJK_SHARE, CONFIDENCE_GATE, MINIMUM_LETTERS,
};
pub use summary::{summary_prompt, usable_summary, wants_summary, SUMMARY_MINIMUM_REPLY_LENGTH};

/// The scalar a fenced code block becomes until the language is decided:
/// U+FFFC OBJECT REPLACEMENT CHARACTER carries no letters, so fences weigh
/// nothing in the decision (HK-214).
pub const CODE_PLACEHOLDER: char = '\u{FFFC}';

/// The language callers speak in when the decision is undecided: the app's
/// own strings are English.
pub const FALLBACK_LANGUAGE: &str = "en";

/// What fenced code is read as, for every language but Chinese (HK-211).
pub const CODE_OMITTED: &str = "code omitted";

/// What fenced code is read as in a Chinese reply (HK-211).
pub const CODE_OMITTED_ZH: &str = "（代码已省略）";

/// The note after a cut reply, joined with a space, for every language but
/// Chinese (HK-211, HK-216).
pub const REPLY_TRUNCATED: &str = "… reply truncated.";

/// The note after a cut Chinese reply, joined with no space (HK-211,
/// HK-216).
pub const REPLY_TRUNCATED_ZH: &str = "……回复已截断。";

/// The Characters a cut may end after (HK-216): ASCII and full-width
/// sentence enders and U+2026 HORIZONTAL ELLIPSIS, each a whole Character,
/// so one a combining mark extends is no ender.
pub const SENTENCE_ENDERS: [&str; 7] = [".", "!", "?", "。", "！", "？", "…"];

/// Spoken text and the language its phrases were chosen for, which the
/// caller hands to the voice so the two can never disagree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpokenReply {
    /// The text to speak; empty when nothing speakable is left.
    pub text: String,
    /// The lowercased primary subtag the phrases were chosen for: the
    /// decision of [`dominant_language`], or [`FALLBACK_LANGUAGE`].
    pub language: String,
}

/// A markdown reply as spoken text, with its language (HK-211, HK-214 to
/// HK-216):
///
/// 1. Fenced code (```` ``` ```` to the nearest ```` ``` ````, across lines;
///    an unclosed fence is no fence) becomes [`CODE_PLACEHOLDER`].
/// 2. The language is decided once, on that text, before any other rule,
///    so a link's target still counts: re-deciding on the output would let
///    the phrases flip it ("好的。 code omitted" reads as English).
/// 3. Every U+FFFC becomes the code-omitted phrase, the input's own ones
///    too, except one a combining scalar extends (Foundation's search
///    skips it); only Chinese is localized, ja and ko included get the
///    English phrases.
/// 4. Inline code, links and images, headings, quotes, `**`, `*`, `__`,
///    `_` and `~~` emphasis, bullets, then every `#`, `*`, `_`, `>` and
///    backtick left, in that order (reordering changes the output: three
///    star bullets pair as italic markers before the bullet rule runs).
/// 5. Every run of whitespace becomes one space, and the result is trimmed
///    of `whitespacesAndNewlines` (which, unlike the collapse, includes
///    U+200B).
/// 6. When `max_chars` is above 0 and the text is longer than `max_chars`
///    Characters, the first `max_chars` are kept up to the last sentence
///    ender among them, or all of them when none is there, trimmed, and
///    the localized truncation note follows. 0 or less never cuts.
pub fn spoken_reply(markdown: &str, max_chars: i64) -> SpokenReply {
    let scalars: Vec<char> = markdown.chars().collect();
    let fenced: String = markdown::replace_fences(&scalars, CODE_PLACEHOLDER)
        .into_iter()
        .collect();

    let language = dominant_language(&fenced).unwrap_or_else(|| FALLBACK_LANGUAGE.to_owned());
    let chinese = language == "zh";
    let code_omitted = if chinese {
        CODE_OMITTED_ZH
    } else {
        CODE_OMITTED
    };

    let mut working: Vec<char> =
        text::replace_unless_extended(&fenced, CODE_PLACEHOLDER, code_omitted)
            .chars()
            .collect();
    working = markdown::strip_inline_code(&working);
    working = markdown::strip_links(&working);
    working = markdown::strip_headings(&working);
    working = markdown::strip_quotes(&working);
    for (delimiter, width) in [('*', 2), ('*', 1), ('_', 2), ('_', 1), ('~', 2)] {
        working = markdown::strip_emphasis(&working, delimiter, width);
    }
    working = markdown::strip_bullets(&working);
    working = markdown::drop_stray_marks(&working);
    let collapsed: String = markdown::collapse_whitespace(&working)
        .into_iter()
        .collect();
    let spoken = text::trim(&collapsed);

    let text = match usize::try_from(max_chars) {
        Ok(limit) if limit > 0 && text::grapheme_count(spoken) > limit => {
            let (note, joiner) = if chinese {
                (REPLY_TRUNCATED_ZH, "")
            } else {
                (REPLY_TRUNCATED, " ")
            };
            format!("{}{joiner}{note}", cut_at_sentence(spoken, limit))
        }
        _ => spoken.to_owned(),
    };
    SpokenReply { text, language }
}

/// The spoken text of [`spoken_reply`] alone.
pub fn speech_text(markdown: &str, max_chars: i64) -> String {
    spoken_reply(markdown, max_chars).text
}

/// The first `limit` Characters of `text` up to and including the last
/// sentence ender among them, or all of them when there is none, trimmed
/// (HK-216).
fn cut_at_sentence(text: &str, limit: usize) -> &str {
    let window = text::grapheme_prefix(text, limit);
    let cut = window
        .grapheme_indices(true)
        .rev()
        .find(|(_, cluster)| SENTENCE_ENDERS.contains(cluster))
        .and_then(|(at, cluster)| window.get(..at + cluster.len()))
        .unwrap_or(window);
    text::trim(cut)
}

/// The language a voice is routed for (HK-210): `language` when the
/// caller gives one, taken as it is (never lowercased, validated or
/// re-checked, so an appended phrase or a too-short string cannot flip the
/// voice), else the decision of [`dominant_language`], else
/// [`FALLBACK_LANGUAGE`].
pub fn voice_language(text: &str, language: Option<&str>) -> String {
    match language {
        Some(language) => language.to_owned(),
        None => dominant_language(text).unwrap_or_else(|| FALLBACK_LANGUAGE.to_owned()),
    }
}
