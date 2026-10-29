//! The language decision that routes spoken text to a voice (HK-212,
//! HK-213), with the Swift app's gates. Swift asked NLLanguageRecognizer
//! for the statistical answer; the core asks the pure-Rust `whatlang`
//! detector, restricted to the languages the recognizer can answer, and
//! holds it to the same gates with the confidence gate re-tuned for its
//! scale ([`CONFIDENCE_GATE`]). whatlang has no statistical answer for
//! CJK, only a count of scripts, so CJK is the script rule's alone
//! (HK-423). `Tests/Fixtures/speech/language-agreement.json` pins where
//! the two agree and records every accepted difference.

use whatlang::{Detector, Lang};

/// The fewest Alphabetic scalars a statistical answer outside CJK needs
/// (HK-213): short strings misfile constantly (`"OK"`, `"Model: Sonnet"`).
pub const MINIMUM_LETTERS: usize = 25;

/// The share of the Alphabetic scalars, inclusive, that CJK scalars need
/// before the script decides (HK-212).
pub const CJK_SHARE: f64 = 0.2;

/// The confidence a statistical answer outside CJK must exceed (HK-213,
/// HK-421).
///
/// Swift's gate was 0.7 on NLLanguageRecognizer's probability for its top
/// hypothesis. whatlang's confidence is another scale: how far its best
/// score stands above the runner-up's, relative to how much text there
/// was, so a clear Dutch sentence scores 0.62 against its nearest
/// neighbour while identifiers around a Chinese sentence reach 0.54. On
/// the agreement corpus the gate sits between the most confident wrong
/// answer (a German sentence whatlang files as French at 0.58) and the
/// least confident right one (English code prose at 0.60): where whatlang
/// is less sure than the recognizer was, the core is undecided and the
/// reply reads in English. Its confidence grows with the length of text at
/// the same lean, so that German sentence written twice passes the gate as
/// French, the one corpus case where the core names a language outside
/// CJK that the Swift app did not (HK-424).
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
///    Alphabetic scalars and a confidence above [`CONFIDENCE_GATE`]
///    (HK-213, HK-421).
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
    (letters >= MINIMUM_LETTERS && confidence > CONFIDENCE_GATE).then(|| code.to_owned())
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
