//! The pure rules of spoken summaries (HK-169 to HK-172): which replies go
//! to the summarizer, the prompt it is given, and which of its answers is
//! spoken. The platform keeps the rest: the one-shot process with its
//! arguments and timeout (HK-280 to HK-285), and the generation counter
//! that drops a summary arriving after its moment.

use crate::text;

/// The fewest Characters a reply needs before it is summarized (HK-169):
/// shorter replies are quick to hear in full and not worth a model call.
pub const SUMMARY_MINIMUM_REPLY_LENGTH: usize = 350;

/// The least a summary may always be shorter than, however short the reply
/// (HK-170).
const SUMMARY_LENGTH_FLOOR: usize = 200;

/// Whether a completed reply goes to the summarizer instead of being spoken
/// in full: only with Spoken Summaries on (off by default, they cost
/// tokens) and a reply of at least [`SUMMARY_MINIMUM_REPLY_LENGTH`]
/// Characters, counted on the reply as it is, untrimmed (HK-169, HK-173).
pub fn wants_summary(reply: &str, speak_summaries: bool) -> bool {
    speak_summaries && text::grapheme_count(reply) >= SUMMARY_MINIMUM_REPLY_LENGTH
}

/// The prompt the summarizer reads on its stdin (HK-172): a fixed English
/// instruction to summarize for reading aloud, plain prose in the reply's
/// own language, then the reply exactly as it is.
pub fn summary_prompt(reply: &str) -> String {
    format!(
        "Summarize the following coding-assistant reply in one or two short \
         sentences meant to be READ ALOUD: what was done or found, and anything \
         the listener must do next. Plain prose only \u{2014} no markdown, no lists, \
         no preamble. Answer in the same language as the reply.\n\nReply to summarize:\n{reply}"
    )
}

/// The summarizer's answer as it is spoken, or `None` when the full reply
/// is spoken instead (HK-170, HK-171): the answer trimmed of Foundation's
/// `whitespacesAndNewlines` is used only when it is not empty and shorter
/// than max(200, reply Characters / 2), the reply counted untrimmed and
/// halved rounding down (HK-173). A summary that is not meaningfully
/// shorter than the reply is worse than the reply. Markdown stays: the
/// caller strips it with no length cap.
pub fn usable_summary(summary: Option<&str>, reply: &str) -> Option<String> {
    let trimmed = text::trim(summary?);
    let limit = SUMMARY_LENGTH_FLOOR.max(text::grapheme_count(reply) / 2);
    (!trimmed.is_empty() && text::grapheme_count(trimmed) < limit).then(|| trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompt_ends_with_the_reply_untouched() {
        let prompt = summary_prompt("  # x\n");
        assert!(prompt.ends_with("\n\nReply to summarize:\n  # x\n"));
        assert!(prompt.contains("READ ALOUD"));
        assert!(prompt.contains("only \u{2014} no markdown"));
        assert!(!prompt.contains("  sentences"));
    }

    #[test]
    fn a_summary_is_measured_trimmed_against_the_untrimmed_reply() {
        assert_eq!(usable_summary(Some(" a "), ""), Some("a".to_owned()));
        assert_eq!(usable_summary(Some("\u{200B}"), "x"), None);
        assert_eq!(usable_summary(None, "x"), None);
        let long = "s".repeat(250);
        assert_eq!(
            usable_summary(Some(&long), &" ".repeat(502)),
            Some(long.clone())
        );
        assert_eq!(usable_summary(Some(&long), &" ".repeat(500)), None);
    }
}
