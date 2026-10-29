//! The speech text rules (slice 2.5): a markdown reply as spoken text with
//! the language its phrases were chosen for, the language decision, the
//! language a voice is routed for, and the pure rules of spoken summaries.
//! The engines and the voices stay with the app: these functions take and
//! return strings and decisions, and never pick a voice, speak or run the
//! summarizer (DESIGN v2.14 A; ADR 0011).

use powerup_core::speech::{self, SpokenReply};

use crate::{contain, CoreBridgeError};

/// Spoken text and the language its phrases were chosen for, which the app
/// hands to the voice so the two can never disagree.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreSpokenReply {
    /// The text to speak; empty when nothing speakable is left.
    pub text: String,
    /// The lowercased primary subtag the phrases were chosen for, "en"
    /// when the language is undecided.
    pub language: String,
}

impl From<SpokenReply> for CoreSpokenReply {
    fn from(reply: SpokenReply) -> Self {
        CoreSpokenReply {
            text: reply.text,
            language: reply.language,
        }
    }
}

/// A markdown reply as spoken text, with its language, cut after
/// `max_chars` Characters when that is above 0 (`speech::spoken_reply`).
#[uniffi::export]
pub fn spoken_reply(markdown: String, max_chars: i64) -> Result<CoreSpokenReply, CoreBridgeError> {
    contain(|| Ok(speech::spoken_reply(&markdown, max_chars).into()))
}

/// The spoken text of [`spoken_reply`] alone (`speech::speech_text`).
#[uniffi::export]
pub fn speech_text(markdown: String, max_chars: i64) -> Result<String, CoreBridgeError> {
    contain(|| Ok(speech::speech_text(&markdown, max_chars)))
}

/// The dominant language of `text` as a lowercased primary subtag, or
/// `None` when undecided (`speech::dominant_language`).
#[uniffi::export]
pub fn dominant_language(text: String) -> Result<Option<String>, CoreBridgeError> {
    contain(|| Ok(speech::dominant_language(&text)))
}

/// The language a voice is routed for: `language` as it is when given,
/// else the decision, else "en" (`speech::voice_language`).
#[uniffi::export]
pub fn voice_language(text: String, language: Option<String>) -> Result<String, CoreBridgeError> {
    contain(|| Ok(speech::voice_language(&text, language.as_deref())))
}

/// Whether a completed reply goes to the summarizer instead of being
/// spoken in full (`speech::wants_summary`).
#[uniffi::export]
pub fn wants_summary(reply: String, speak_summaries: bool) -> Result<bool, CoreBridgeError> {
    contain(|| Ok(speech::wants_summary(&reply, speak_summaries)))
}

/// The summarizer's answer as it is spoken, or `None` when the full reply
/// is spoken instead (`speech::usable_summary`).
#[uniffi::export]
pub fn usable_summary(
    summary: Option<String>,
    reply: String,
) -> Result<Option<String>, CoreBridgeError> {
    contain(|| Ok(speech::usable_summary(summary.as_deref(), &reply)))
}

/// The prompt the summarizer reads on its stdin (`speech::summary_prompt`).
#[uniffi::export]
pub fn summary_prompt(reply: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(speech::summary_prompt(&reply)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_crosses_with_its_language() {
        assert_eq!(
            spoken_reply("好的。\n```\nlet x = 1\n```\n完成了。".into(), 0).unwrap(),
            CoreSpokenReply {
                text: "好的。 （代码已省略） 完成了。".into(),
                language: "zh".into()
            }
        );
        assert_eq!(
            spoken_reply(String::new(), i64::MIN).unwrap(),
            CoreSpokenReply {
                text: String::new(),
                language: "en".into()
            }
        );
        assert_eq!(
            speech_text("**Done.** It works now.".into(), 6).unwrap(),
            "Done. \u{2026} reply truncated."
        );
    }

    #[test]
    fn the_decision_and_the_override_cross_as_options() {
        assert_eq!(dominant_language("OK".into()).unwrap(), None);
        assert_eq!(
            dominant_language("テストは全部通りました".into()).unwrap(),
            Some("ja".into())
        );
        assert_eq!(voice_language("OK".into(), None).unwrap(), "en");
        assert_eq!(
            voice_language("这是一个测试".into(), Some("EN".into())).unwrap(),
            "EN"
        );
    }

    #[test]
    fn summary_rules_cross() {
        let reply = "a".repeat(350);
        assert!(wants_summary(reply.clone(), true).unwrap());
        assert!(!wants_summary(reply.clone(), false).unwrap());
        assert_eq!(
            usable_summary(Some("  Fixed it.\n".into()), reply.clone()).unwrap(),
            Some("Fixed it.".into())
        );
        assert_eq!(usable_summary(None, reply.clone()).unwrap(), None);
        assert_eq!(usable_summary(Some(" ".into()), reply).unwrap(), None);
        assert!(summary_prompt("x".into())
            .unwrap()
            .ends_with("\n\nReply to summarize:\nx"));
    }
}
