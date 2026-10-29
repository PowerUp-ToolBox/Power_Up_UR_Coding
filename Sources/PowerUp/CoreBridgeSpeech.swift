import Foundation
import PowerUpCore

/// The speech text rules (slice 2.5, DESIGN v2.14; ADR 0011): the core owns
/// what a markdown reply sounds like (the code placeholder before the
/// language decision, the fixed stripping order, the cut at a sentence
/// ender with its localized note), the language decision with its gates,
/// the language a voice is routed for, and the pure rules of spoken
/// summaries (which replies are summarized, the prompt, which answer is
/// spoken); TTSService keeps the voices (resolution, ranking, the
/// simplified or traditional Chinese region), the synthesizer and audio
/// routing, SummaryService the one-shot process, and AppState the
/// generation counter and the fallback to the full reply.
///
/// The reply and summary rules run on the main actor, inside AppState and
/// TTSService; the prompt and the summary check run on SummaryService's
/// detached task; like every `CoreBridge` function, they are safe from
/// either. A failed call never speaks raw markdown or fenced code: the text
/// wrappers answer nil and the caller says nothing, a failed decision reads
/// as undecided (English), and a failed summary rule speaks the full reply
/// instead.
extension CoreBridge {
    /// A markdown reply as spoken text, with the lowercased primary subtag
    /// its phrases were chosen for ("en" when undecided), cut after
    /// `maxChars` Characters when that is above 0; nil when the core fails,
    /// and then nothing is spoken.
    /// Cases: `Tests/Fixtures/speech/spoken-reply.json`.
    static func spokenReply(fromMarkdown markdown: String,
                            maxChars: Int) -> (text: String, language: String)? {
        call("spokenReply", fallback: nil) {
            let reply = try PowerUpCore.spokenReply(markdown: markdown, maxChars: Int64(maxChars))
            return (text: reply.text, language: reply.language)
        }
    }

    /// The spoken text of `spokenReply` alone; nil when the core fails, and
    /// then nothing is spoken. Cases: `Tests/Fixtures/speech/speech-text.json`.
    static func speechText(fromMarkdown markdown: String, maxChars: Int) -> String? {
        call("speechText", fallback: nil) {
            try PowerUpCore.speechText(markdown: markdown, maxChars: Int64(maxChars))
        }
    }

    /// The dominant language of `text` as a lowercased primary subtag
    /// ("zh" for simplified and traditional alike), or nil when undecided,
    /// which callers read as English. A failed call is nil too, so the text
    /// is spoken in English. Cases: `Tests/Fixtures/speech/language.json`
    /// and `language-agreement.json`.
    static func dominantLanguage(of text: String) -> String? {
        call("dominantLanguage", fallback: nil) { try PowerUpCore.dominantLanguage(text: text) }
    }

    /// The language a voice is routed for: `language` as it is when the
    /// caller gives one, else the decision for `text`, else "en". When the
    /// core fails it is `language`, else "en", so a caller's choice still
    /// wins. Cases: `Tests/Fixtures/speech/voice-language.json`.
    static func voiceLanguage(for text: String, language: String?) -> String {
        call("voiceLanguage", fallback: language ?? "en") {
            try PowerUpCore.voiceLanguage(text: text, language: language)
        }
    }

    /// Whether a completed reply goes to the summarizer instead of being
    /// spoken in full; false when the core fails, and then the full reply
    /// is spoken with no model call.
    /// Cases: `Tests/Fixtures/speech/summary-threshold.json`.
    static func wantsSummary(of reply: String, speakSummaries: Bool) -> Bool {
        call("wantsSummary", fallback: false) {
            try PowerUpCore.wantsSummary(reply: reply, speakSummaries: speakSummaries)
        }
    }

    /// The summarizer's answer as it is spoken (trimmed, markdown kept for
    /// the caller to strip), or nil when the full reply is spoken instead;
    /// nil when the core fails too.
    /// Cases: `Tests/Fixtures/speech/summary-acceptance.json`.
    static func usableSummary(_ summary: String?, for reply: String) -> String? {
        call("usableSummary", fallback: nil) {
            try PowerUpCore.usableSummary(summary: summary, reply: reply)
        }
    }

    /// The prompt the summarizer reads on its stdin; nil when the core
    /// fails, and then no summarizer runs and the full reply is spoken.
    /// Cases: `Tests/Fixtures/speech/summary-prompt.json`.
    static func summaryPrompt(for reply: String) -> String? {
        call("summaryPrompt", fallback: nil) { try PowerUpCore.summaryPrompt(reply: reply) }
    }
}
