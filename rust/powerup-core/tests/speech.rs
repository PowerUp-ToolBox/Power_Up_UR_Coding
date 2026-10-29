//! Plays `Tests/Fixtures/speech/` (spec #100 slice 2.5, ticket #160)
//! against the core: the tables `SpeechFixtureTests` plays through the
//! Swift speech rules. Strings are compared exactly, scalar for scalar.
//! A text descriptor (Tests/Fixtures/README.md, `speech/`) is a string, or
//! a list of strings and `{"repeat": s, "times": n}` parts joined in order;
//! it is resolved on both sides before comparing.
//!
//! `language-agreement.json` holds the Swift app's decision for each
//! sentence in `expected.swift`; a case whose `expected` also has `core`
//! records an accepted difference, and the core must give exactly that
//! instead. Every other case must agree with Swift.

mod support;

use powerup_core::speech::{
    cjk_script_language, dominant_language, speech_text, spoken_reply, summary_prompt,
    usable_summary, voice_language, wants_summary, SENTENCE_ENDERS,
};
use serde_json::{json, Value};
use support::case_table;

fn fail(
    file: &str,
    name: &str,
    reason: &str,
    input: &Value,
    expected: &Value,
    actual: &Value,
) -> String {
    format!(
        "{file} case {name:?} failed (guards: {reason})\n  input:    {input}\n  expected: {expected}\n  actual:   {actual}"
    )
}

/// A text descriptor, or `None` for JSON null.
fn optional_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) => Some(text.clone()),
        Value::Array(parts) => Some(
            parts
                .iter()
                .map(|part| match part {
                    Value::String(text) => text.clone(),
                    Value::Object(fields) if fields.len() == 2 => {
                        let piece = fields
                            .get("repeat")
                            .and_then(Value::as_str)
                            .unwrap_or_else(|| panic!("not a repeat part: {part}"));
                        let times = fields
                            .get("times")
                            .and_then(Value::as_u64)
                            .unwrap_or_else(|| panic!("not a repeat part: {part}"));
                        piece.repeat(
                            usize::try_from(times)
                                .unwrap_or_else(|_| panic!("not a repeat count: {part}")),
                        )
                    }
                    _ => panic!("not a text part: {part}"),
                })
                .collect(),
        ),
        _ => panic!("not a text descriptor: {value}"),
    }
}

fn text(value: &Value) -> String {
    optional_text(value).unwrap_or_else(|| panic!("a text descriptor is required here: {value}"))
}

fn integer(value: &Value) -> i64 {
    value
        .as_i64()
        .unwrap_or_else(|| panic!("not an integer: {value}"))
}

fn flag(value: &Value) -> bool {
    value
        .as_bool()
        .unwrap_or_else(|| panic!("not a bool: {value}"))
}

fn optional(text: Option<String>) -> Value {
    text.map_or(Value::Null, Value::String)
}

/// Plays one table: `run` maps an input to the actual value, `expected`
/// resolves a case's expected value into the same shape.
fn play(file: &str, run: impl Fn(&Value) -> Value, expected: impl Fn(&Value) -> Value) {
    let table = case_table("speech", file);
    assert!(
        table.captured_against.is_some(),
        "{file}: the expected values were captured, say from what"
    );
    let failures: Vec<String> = table
        .cases
        .iter()
        .filter_map(|case| {
            let actual = run(&case.input);
            let wanted = expected(&case.expected);
            (actual != wanted).then(|| {
                fail(
                    file,
                    &case.name,
                    &case.reason,
                    &case.input,
                    &wanted,
                    &actual,
                )
            })
        })
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn as_is(value: &Value) -> Value {
    value.clone()
}

#[test]
fn speech_text_cases() {
    play(
        "speech-text.json",
        |input| {
            json!(speech_text(
                &text(&input["text"]),
                integer(&input["maxChars"])
            ))
        },
        |expected| json!(text(expected)),
    );
}

#[test]
fn spoken_reply_cases() {
    play(
        "spoken-reply.json",
        |input| {
            let spoken = spoken_reply(&text(&input["text"]), integer(&input["maxChars"]));
            json!({"text": spoken.text, "language": spoken.language})
        },
        as_is,
    );
}

#[test]
fn speech_text_is_the_spoken_reply_text() {
    for file in ["speech-text.json", "spoken-reply.json"] {
        for case in case_table("speech", file).cases {
            let (markdown, max_chars) =
                (text(&case.input["text"]), integer(&case.input["maxChars"]));
            assert_eq!(
                speech_text(&markdown, max_chars),
                spoken_reply(&markdown, max_chars).text,
                "{file} case {:?}",
                case.name
            );
        }
    }
}

#[test]
fn language_cases() {
    play(
        "language.json",
        |input| optional(dominant_language(&text(input))),
        as_is,
    );
}

/// The core's decision must be `expected.core` where the table records an
/// accepted difference and `expected.swift` everywhere else. A recorded
/// difference must really differ, so a stale record cannot linger, and it
/// must be one of the three kinds the ledger accepts: the core undecided,
/// so the reply reads in English (HK-421, HK-422, HK-423); CJK text the
/// core decides by its script where the recognizer named another CJK
/// language (HK-420, HK-423); or German the core reads as French, which
/// only one sentence repeated does (HK-424). Outside these the core never
/// names a language the Swift app did not.
#[test]
fn language_agreement_cases() {
    let file = "language-agreement.json";
    let table = case_table("speech", file);
    let mut failures = Vec::new();
    for case in &table.cases {
        let fields = case
            .expected
            .as_object()
            .unwrap_or_else(|| panic!("{file} case {:?}: not an agreement expectation", case.name));
        assert!(
            fields.keys().all(|key| key == "swift" || key == "core"),
            "{file} case {:?}: unknown key in {}",
            case.name,
            case.expected
        );
        let swift = fields
            .get("swift")
            .unwrap_or_else(|| panic!("{file} case {:?}: no swift decision", case.name));
        let wanted = match fields.get("core") {
            Some(core) => {
                let input = text(&case.input);
                let cjk = |value: &Value| matches!(value.as_str(), Some("zh" | "ja" | "ko"));
                let by_script =
                    cjk(core) && cjk(swift) && core.as_str() == cjk_script_language(&input);
                assert!(
                    core.is_null() || by_script || (core == "fr" && swift == "de"),
                    "{file} case {:?}: {core} where Swift said {swift} is no accepted kind of difference",
                    case.name
                );
                assert_ne!(
                    core, swift,
                    "{file} case {:?}: a recorded difference must differ",
                    case.name
                );
                core
            }
            None => swift,
        };
        let actual = optional(dominant_language(&text(&case.input)));
        if &actual != wanted {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.input,
                wanted,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn summary_threshold_cases() {
    play(
        "summary-threshold.json",
        |input| {
            json!(wants_summary(
                &text(&input["reply"]),
                flag(&input["speakSummaries"])
            ))
        },
        as_is,
    );
}

#[test]
fn summary_acceptance_cases() {
    play(
        "summary-acceptance.json",
        |input| {
            let summary = optional_text(&input["summary"]);
            optional(usable_summary(summary.as_deref(), &text(&input["reply"])))
        },
        |expected| optional(optional_text(expected)),
    );
}

#[test]
fn summary_prompt_cases() {
    play(
        "summary-prompt.json",
        |input| json!(summary_prompt(&text(input))),
        as_is,
    );
}

#[test]
fn voice_language_cases() {
    play(
        "voice-language.json",
        |input| {
            let language = optional_text(&input["language"]);
            json!(voice_language(&text(&input["text"]), language.as_deref()))
        },
        as_is,
    );
}

/// The ender list the core cuts at is the one the table's coverage test
/// checks (`SpeechFixtureTests.testSpeechTextTableCoversTheTruncationEdges`).
#[test]
fn every_sentence_ender_is_one_character() {
    assert_eq!(SENTENCE_ENDERS, [".", "!", "?", "。", "！", "？", "…"]);
    for ender in SENTENCE_ENDERS {
        assert_eq!(powerup_core::text::grapheme_count(ender), 1, "{ender:?}");
    }
}
