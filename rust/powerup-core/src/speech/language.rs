//! The language decision that routes spoken text to a voice (HK-212,
//! HK-213), with the Swift app's gates. Swift asked NLLanguageRecognizer
//! for the statistical answer; the core asks the pure-Rust `whatlang`
//! detector, restricted to the languages the recognizer can answer, and
//! holds it to the same letter gate. Where Swift then asked for
//! confidence, the core asks for evidence in a Latin or Cyrillic script
//! (`evidence`, HK-425), on whose terse prose whatlang is confidently
//! wrong, and for a confidence re-tuned to its scale in the others
//! ([`CONFIDENCE_GATE`]). whatlang has no statistical answer for CJK, only
//! a count of scripts, so CJK is the script rule's alone (HK-423).
//! `Tests/Fixtures/speech/language-agreement.json` pins where the two
//! agree and records every accepted difference.

use whatlang::{Detector, Lang};

use super::evidence;

/// The fewest Alphabetic scalars a statistical answer outside CJK needs
/// (HK-213): short strings misfile constantly (`"OK"`, `"Model: Sonnet"`).
pub const MINIMUM_LETTERS: usize = 25;

/// The share of the Alphabetic scalars, inclusive, that CJK scalars need
/// before the script decides (HK-212).
pub const CJK_SHARE: f64 = 0.2;

/// The confidence a statistical answer must exceed in a script without
/// evidence (HK-213, HK-421): not Latin, Cyrillic or CJK (Arabic,
/// Devanagari, Greek, Hebrew, Thai, …).
///
/// Swift's gate was 0.7 on NLLanguageRecognizer's probability for its top
/// hypothesis. whatlang's confidence is another scale: how far its best
/// score stands above the runner-up's, relative to how much text there
/// was. It grows with the length of text at the same lean (HK-424), and on
/// short Latin-script prose it is high for wrong answers too (an English
/// sentence French at 0.93), so a Latin or Cyrillic answer is checked
/// against the text's letters and function words instead, at any
/// confidence (HK-425). In the other scripts most languages own theirs.
/// The value was first tuned on Latin-script sentences, when the gate
/// still held them; the agreement corpus measures it in the scripts it
/// holds now (its ar, ur, hi, mr, he, el, th, ka, hy, bn and ta cases).
/// whatlang's right answers there are mostly 1.00 and decide from 0.62;
/// short Hindi and Arabic replies around an identifier (0.48 to 0.57) and
/// one Marathi sentence (0.29) fall under it and read in English; and the
/// neighbour whatlang names for a language the core does not answer
/// (Persian, Nepali, Central Kurdish, Pashto) stays under it, at 0.37 or
/// less, where the app read them as Arabic, Hindi or Urdu.
pub const CONFIDENCE_GATE: f64 = 0.59;

/// The languages whatlang may answer, with the subtag the core returns
/// for each: the ones NLLanguageRecognizer can answer as well (listed
/// from its hypotheses for every script on macOS 27.2), so the core never
/// names a language the Swift app could not have chosen. whatlang knows
/// no Icelandic, Kazakh, Lao, Tibetan or Cherokee, and the recognizer
/// none of whatlang's 23 others (Esperanto, Afrikaans, Latin, Javanese,
/// Amharic, …).
const LANGUAGES: [(Lang, &str); 47] = [
    (Lang::Eng, "en"),
    (Lang::Spa, "es"),
    (Lang::Por, "pt"),
    (Lang::Ita, "it"),
    (Lang::Fra, "fr"),
    (Lang::Deu, "de"),
    (Lang::Pol, "pl"),
    (Lang::Nob, "nb"),
    (Lang::Dan, "da"),
    (Lang::Swe, "sv"),
    (Lang::Fin, "fi"),
    (Lang::Tur, "tr"),
    (Lang::Nld, "nl"),
    (Lang::Hun, "hu"),
    (Lang::Ces, "cs"),
    (Lang::Ron, "ro"),
    (Lang::Hrv, "hr"),
    (Lang::Vie, "vi"),
    (Lang::Ind, "id"),
    (Lang::Slk, "sk"),
    (Lang::Cat, "ca"),
    (Lang::Rus, "ru"),
    (Lang::Ukr, "uk"),
    (Lang::Bul, "bg"),
    (Lang::Ara, "ar"),
    (Lang::Urd, "ur"),
    (Lang::Hin, "hi"),
    (Lang::Mar, "mr"),
    (Lang::Heb, "he"),
    (Lang::Ell, "el"),
    (Lang::Tha, "th"),
    (Lang::Kat, "ka"),
    (Lang::Hye, "hy"),
    (Lang::Ben, "bn"),
    (Lang::Tam, "ta"),
    (Lang::Tel, "te"),
    (Lang::Kan, "kn"),
    (Lang::Mal, "ml"),
    (Lang::Guj, "gu"),
    (Lang::Pan, "pa"),
    (Lang::Ori, "or"),
    (Lang::Mya, "my"),
    (Lang::Khm, "km"),
    (Lang::Sin, "si"),
    (Lang::Cmn, "zh"),
    (Lang::Jpn, "ja"),
    (Lang::Kor, "ko"),
];

/// The subtag of a language the core may answer.
fn subtag(lang: Lang) -> Option<&'static str> {
    LANGUAGES
        .iter()
        .find(|(known, _)| *known == lang)
        .map(|(_, code)| *code)
}

/// The statistical answer and its confidence: whatlang's best language
/// among [`LANGUAGES`], or `None` when it finds none (no letters of a
/// script it knows) or names a language outside the list (a script with a
/// single language, which its allowlist does not filter).
///
/// The fence placeholder is read as a space: it carries no letters, but
/// whatlang reads every scalar outside ASCII punctuation and digits as part
/// of a word, so each placeholder added trigrams, and with them confidence,
/// to the reply around it (a German reply with a code block came out
/// French; HK-214, HK-424).
fn statistical_answer(text: &str) -> Option<(&'static str, f64)> {
    let languages = LANGUAGES.iter().map(|(lang, _)| *lang).collect();
    let text = text.replace(super::CODE_PLACEHOLDER, " ");
    let info = Detector::with_allowlist(languages).detect(&text)?;
    subtag(info.lang()).map(|code| (code, info.confidence()))
}

/// The dominant language of `text` as a lowercased primary BCP-47 subtag
/// (`zh` for simplified and traditional Chinese alike), or `None` for
/// undecided, which callers read as English:
///
/// 1. Empty text is undecided.
/// 2. CJK decides by its script ([`cjk_script_language`]) once CJK scalars
///    are at least 20% of the Alphabetic scalars: any kana means ja, else
///    any hangul ko, else zh. Swift trusted NLLanguageRecognizer's zh, ja or ko
///    first and fell back to this rule; whatlang's zh, ja or ko is no
///    statistical answer but a count of scripts, and its counts take the
///    whole Halfwidth and Fullwidth Forms block for hangul (so "完成！！！"
///    and "はい！！！" came out ko) and weigh kana against Han by its own
///    5% share, so the core decides CJK by the script rule alone (HK-420,
///    HK-423). The rule is also why "我修改了 parseJSON() 函数", which the
///    recognizer filed as Turkish, is zh (HK-212).
/// 3. A zh, ja or ko answer from whatlang without that script evidence is
///    undecided: it counted only full-width forms, digits or punctuation
///    (HK-423).
/// 4. Otherwise a statistical answer is admitted only with at least 25
///    Alphabetic scalars (HK-213) and, for a language written in a Latin
///    or Cyrillic script, when the text's letters fit its alphabet and its
///    function words point to it alone (HK-425), for any other with a
///    confidence above [`CONFIDENCE_GATE`] (HK-421).
pub fn dominant_language(text: &str) -> Option<String> {
    if text.is_empty() {
        return None;
    }
    if let Some(script) = cjk_script_language(text) {
        return Some(script.to_owned());
    }
    let (code, confidence) = statistical_answer(text)?;
    if matches!(code, "zh" | "ja" | "ko") {
        return None;
    }
    let letters = text.chars().filter(|scalar| scalar.is_alphabetic()).count();
    if letters < MINIMUM_LETTERS {
        return None;
    }
    let admitted = evidence::confirms(text, code).unwrap_or(confidence > CONFIDENCE_GATE);
    admitted.then(|| code.to_owned())
}

/// The language CJK script implies, when CJK scalars are at least 20% of
/// the Alphabetic scalars (so an English sentence quoting a character or
/// two stays English): any kana means ja, else any hangul ko, else zh.
/// Only Alphabetic scalars count, and only these ranges are CJK: Han
/// U+4E00..U+9FFF, U+3400..U+4DBF and U+F900..U+FAFF (no extension B),
/// kana U+3040..U+30FF (no halfwidth katakana), hangul U+AC00..U+D7AF,
/// U+1100..U+11FF and U+3130..U+318F.
pub fn cjk_script_language(text: &str) -> Option<&'static str> {
    let (mut letters, mut han, mut kana, mut hangul) = (0usize, 0usize, 0usize, 0usize);
    for scalar in text.chars().filter(|scalar| scalar.is_alphabetic()) {
        letters += 1;
        match u32::from(scalar) {
            0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0xF900..=0xFAFF => han += 1,
            0x3040..=0x30FF => kana += 1,
            0xAC00..=0xD7AF | 0x1100..=0x11FF | 0x3130..=0x318F => hangul += 1,
            _ => {}
        }
    }
    let cjk = han + kana + hangul;
    if letters == 0 || cjk == 0 || (cjk as f64) / (letters as f64) < CJK_SHARE {
        return None;
    }
    Some(if kana > 0 {
        "ja"
    } else if hangul > 0 {
        "ko"
    } else {
        "zh"
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_listed_language_has_one_subtag() {
        for (index, (lang, code)) in LANGUAGES.iter().enumerate() {
            assert!(
                LANGUAGES[index + 1..]
                    .iter()
                    .all(|(other, _)| other != lang),
                "{lang:?}"
            );
            assert_eq!(subtag(*lang), Some(*code));
            assert!(code.len() == 2 && code.chars().all(|c| c.is_ascii_lowercase()));
        }
        assert_eq!(subtag(Lang::Epo), None);
        assert_eq!(subtag(Lang::Afr), None);
        assert_eq!(subtag(Lang::Amh), None);
    }

    #[test]
    fn the_latin_and_cyrillic_languages_and_only_they_need_evidence() {
        let evidenced: Vec<&str> = LANGUAGES
            .iter()
            .map(|(_, code)| *code)
            .filter(|code| evidence::confirms("", code).is_some())
            .collect();
        assert_eq!(
            evidenced,
            [
                "en", "es", "pt", "it", "fr", "de", "pl", "nb", "da", "sv", "fi", "tr", "nl", "hu",
                "cs", "ro", "hr", "vi", "id", "sk", "ca", "ru", "uk", "bg"
            ]
        );
    }

    #[test]
    fn a_confident_answer_the_evidence_does_not_back_is_undecided() {
        // whatlang: French at 0.93, Portuguese at 0.87; NLLanguageRecognizer:
        // English for both. Undecided reads as English (HK-425).
        for english in [
            "Same connection, de-dup and drop paths as a real pad (a drop releases held buttons).",
            "to the system default (queried explicitly, so a previous override never",
        ] {
            let (_, confidence) = statistical_answer(english).unwrap_or(("", 0.0));
            assert!(confidence > CONFIDENCE_GATE, "{english:?}");
            assert_eq!(dominant_language(english), None);
        }
        // German written twice: whatlang leans French at 0.96 (HK-424).
        let twice = "Bitte prüfe, ob die neue Konfiguration für dich so passt. ".repeat(2);
        assert_eq!(statistical_answer(&twice).map(|(code, _)| code), Some("fr"));
        assert_eq!(dominant_language(&twice), None);
    }

    #[test]
    fn the_share_is_inclusive_and_counts_only_alphabetic_scalars() {
        assert_eq!(cjk_script_language("test 中"), Some("zh"));
        assert_eq!(cjk_script_language("tests 中"), None);
        assert_eq!(cjk_script_language("中 1234567890"), Some("zh"));
        assert_eq!(cjk_script_language(""), None);
        assert_eq!(cjk_script_language("。、"), None);
    }

    #[test]
    fn a_script_without_listed_languages_is_undecided() {
        // whatlang answers Amharic for any Ethiopic text, whatever its
        // allowlist; the recognizer has no answer, and neither has the core.
        assert_eq!(
            statistical_answer("ሰላም ሰላም ሰላም ሰላም ሰላም ሰላም ሰላም ሰላም ሰላም"),
            None
        );
        // Lao is a script whatlang does not know.
        assert_eq!(statistical_answer("ສະບາຍດີ ສະບາຍດີ ສະບາຍດີ ສະບາຍດີ"), None);
        assert_eq!(dominant_language("1234 5678"), None);
    }

    #[test]
    fn full_width_forms_never_decide_a_cjk_language() {
        // whatlang counts U+FF00..U+FFEF as hangul and says Korean for all
        // of these; the script rule does not (HK-423).
        assert_eq!(
            statistical_answer("完成！！！").map(|(code, _)| code),
            Some("ko")
        );
        assert_eq!(dominant_language("完成！！！").as_deref(), Some("zh"));
        assert_eq!(dominant_language("はい！！！").as_deref(), Some("ja"));
        assert_eq!(dominant_language("ＯＫです").as_deref(), Some("ja"));
        assert_eq!(
            dominant_language("完了しました（ｖ２．０）").as_deref(),
            Some("ja")
        );
        assert_eq!(dominant_language("（１２／１２）"), None);
        assert_eq!(dominant_language("Ｈｅｌｌｏ\u{3000}Ｗｏｒｌｄ"), None);
        // Past the letter gate, only the rule that whatlang's zh, ja or ko
        // without the script is undecided keeps full-width English from a
        // Korean voice: no evidence is held for ko, and 1.00 clears the
        // confidence gate.
        let english = "Ｔｈｅ\u{3000}ｂｕｉｌｄ\u{3000}ｐａｓｓｅｄ\u{3000}ａｎｄ\u{3000}ａｌｌ\u{3000}ｔｅｓｔｓ\u{3000}ａｒｅ\u{3000}ｇｒｅｅｎ\u{3000}ｎｏｗ";
        assert!(
            english
                .chars()
                .filter(|scalar| scalar.is_alphabetic())
                .count()
                >= MINIMUM_LETTERS
        );
        assert_eq!(
            statistical_answer(english).map(|(code, _)| code),
            Some("ko")
        );
        assert_eq!(dominant_language(english), None);
    }

    #[test]
    fn the_confidence_gate_decides_a_script_without_evidence() {
        // Hindi around an identifier, whatlang's Hindi either side of the
        // gate; NLLanguageRecognizer says Hindi at 1.00 for both (HK-421).
        let above = "मैंने टेस्ट जोड़े और build अब ठीक है";
        let below = "मैंने CI ठीक कर दिया है, अब build हरा है।";
        for (text, decided) in [(above, true), (below, false)] {
            assert_eq!(evidence::confirms(text, "hi"), None);
            let (code, confidence) = statistical_answer(text).unwrap_or(("", 0.0));
            assert_eq!(code, "hi", "{text:?}");
            assert!(
                (confidence - CONFIDENCE_GATE).abs() < 0.05,
                "{text:?}: {confidence}"
            );
            assert_eq!(
                confidence > CONFIDENCE_GATE,
                decided,
                "{text:?}: {confidence}"
            );
            assert_eq!(dominant_language(text).is_some(), decided, "{text:?}");
        }
        assert_eq!(dominant_language(above).as_deref(), Some("hi"));
        // Persian, which the core does not answer: whatlang's Urdu stays
        // under the gate.
        let persian = "دو آزمون تازه برای ورودی خالی به پرونده parser.rs اضافه کردم.";
        let (code, confidence) = statistical_answer(persian).unwrap_or(("", 1.0));
        assert_eq!(code, "ur");
        assert!(confidence < CONFIDENCE_GATE, "{confidence}");
        assert_eq!(dominant_language(persian), None);
    }

    #[test]
    fn any_kana_decides_japanese_however_much_han() {
        // whatlang answers Chinese where kana are 5% or less of Han and kana.
        let japanese = "株式会社日本経済新聞社代表取締役社長の挨拶";
        assert_eq!(
            statistical_answer(japanese).map(|(code, _)| code),
            Some("zh")
        );
        assert_eq!(dominant_language(japanese).as_deref(), Some("ja"));
    }

    #[test]
    fn the_fence_placeholder_weighs_nothing() {
        for reply in [
            "Bitte prüfe, ob die neue Konfiguration für dich so passt.",
            "I refactored the parser so it handles empty arrays, and every test passes now.",
        ] {
            let alone = statistical_answer(reply);
            for fenced in [
                format!("{reply}\n\n\u{FFFC}"),
                format!("\u{FFFC} {reply} \u{FFFC}\u{FFFC}"),
            ] {
                assert_eq!(statistical_answer(&fenced), alone, "{fenced:?}");
                assert_eq!(dominant_language(&fenced), dominant_language(reply));
            }
        }
    }
}
