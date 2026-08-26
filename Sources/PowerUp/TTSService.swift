import Foundation
import AVFAudio
import NaturalLanguage

/// Text-to-speech service wrapping AVSpeechSynthesizer. Also hosts the pure
/// `speechText(fromMarkdown:maxChars:)` helper that turns a Claude reply into
/// something pleasant to have read aloud.
@MainActor
final class TTSService: NSObject, ObservableObject {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let quality: String
    }

    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var availableVoices: [Voice] = []

    /// Fired on both didFinish and didCancel.
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    /// The utterance currently being spoken. Delegate callbacks for anything
    /// else are stale — e.g. the asynchronous didCancel produced by the stop()
    /// inside speak() must not clear the *new* utterance's isSpeaking.
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
        availableVoices = Self.loadAvailableVoices()
    }

    // MARK: - Speak / stop

    /// `language` pins voice routing to a caller-decided language (a lowercased
    /// primary subtag like "en" or "zh"); nil means detect it from `text`.
    /// Callers that already made a language decision — `spokenReply`'s
    /// localized phrases, AppState's English announcements — pass it so an
    /// injected phrase or a too-short string can never flip the voice.
    func speak(_ text: String, voiceID: String?, rate: Float, language: String? = nil) {
        stop()

        guard !text.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = Self.resolveVoice(text: text, voiceID: voiceID, language: language)

        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        currentUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: - Language detection

    /// The dominant language of `text`, as the lowercased primary BCP-47
    /// subtag (e.g. "en", "zh", "ja") — collapsing script variants like
    /// zh-Hans/zh-Hant down to "zh". Returns nil when no language can be
    /// determined (empty text, text too short/ambiguous for the recognizer).
    static func dominantLanguageCode(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let recognized = recognizer.dominantLanguage.map { primarySubtag(of: $0.rawValue) }

        // Trust the recognizer whenever it lands on a CJK language; otherwise
        // double-check against the script content. The statistical model can
        // badly misfile short mixed strings — "我修改了 parseJSON() 函数"
        // comes back Turkish — but scripts can't lie: kana only writes
        // Japanese, hangul only Korean, Han with neither is Chinese.
        if let recognized, ["zh", "ja", "ko"].contains(recognized) { return recognized }
        if let scriptLanguage = cjkScriptLanguage(of: text) { return scriptLanguage }

        // Latin-script answers need gating too: the recognizer misfiles short
        // strings constantly ("Model: Sonnet" → German, "OK" → Polish), and a
        // wrong answer here routes the whole utterance to a foreign voice.
        // Script evidence (above) is reliable at any length; a statistical
        // answer is trusted only when it's backed by a reasonable amount of
        // text AND the recognizer itself is confident. Otherwise admit "don't
        // know" — callers fall back to English, the right default for an app
        // whose own strings are English.
        guard recognized != nil else { return nil }
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
        }
        guard letters >= 25 else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1).values.max() ?? 0
        guard confidence > 0.7 else { return nil }
        return recognized
    }

    /// Language implied by the text's CJK script content, when CJK letters are
    /// a meaningful share (≥ 20%) of all letters — nil otherwise, so an
    /// English sentence that merely quotes a character or two is unaffected.
    private static func cjkScriptLanguage(of text: String) -> String? {
        var han = 0, kana = 0, hangul = 0, letters = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            letters += 1
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                han += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                hangul += 1
            default:
                break
            }
        }
        let cjk = han + kana + hangul
        guard letters > 0, cjk > 0, Double(cjk) / Double(letters) >= 0.2 else { return nil }
        if kana > 0 { return "ja" }
        if hangul > 0 { return "ko" }
        return "zh"
    }

    /// Lowercased primary subtag of a BCP-47-ish tag: "zh-Hans" -> "zh",
    /// "en-US" -> "en", "en" -> "en".
    private static func primarySubtag(of bcp47Tag: String) -> String {
        bcp47Tag.split(separator: "-").first.map(String.init)?.lowercased()
            ?? bcp47Tag.lowercased()
    }

    // MARK: - Voice resolution

    /// All installed voices whose language's primary subtag matches
    /// `languagePrefix` (case-insensitive), excluding novelty voices (e.g.
    /// Zarvox, Bubbles — `voiceTraits.contains(.isNoveltyVoice)`), the
    /// "eloquence" synthesis-engine voices (identifier contains "eloquence"),
    /// and the legacy low-quality bucket (identifier has the
    /// "com.apple.speech.synthesis.voice" prefix — e.g. the robotic "compact
    /// Samantha"). Sorted best-first: quality desc, then Samantha first among
    /// voices of the same quality tier (a no-op for any non-English list,
    /// since only the en-US system voice is named Samantha), then name
    /// ascending.
    static func rankedVoices(languagePrefix: String) -> [AVSpeechSynthesisVoice] {
        let target = languagePrefix.lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard primarySubtag(of: voice.language) == target else { return false }
                return passesQualityExclusions(voice)
            }
            .sorted { lhs, rhs in
                let lhsRank = qualityRank(lhs.quality)
                let rhsRank = qualityRank(rhs.quality)
                if lhsRank != rhsRank { return lhsRank > rhsRank }

                let lhsIsSamantha = lhs.name == "Samantha"
                let rhsIsSamantha = rhs.name == "Samantha"
                if lhsIsSamantha != rhsIsSamantha { return lhsIsSamantha }

                return lhs.name < rhs.name
            }
    }

    /// All installed en-* voices (same exclusions as `rankedVoices(languagePrefix:)`).
    static func rankedVoices() -> [AVSpeechSynthesisVoice] {
        rankedVoices(languagePrefix: "en")
    }

    private static func passesQualityExclusions(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard !voice.voiceTraits.contains(.isNoveltyVoice) else { return false }
        let identifier = voice.identifier.lowercased()
        guard !identifier.contains("eloquence") else { return false }
        guard !identifier.hasPrefix("com.apple.speech.synthesis.voice") else { return false }
        return true
    }

    /// 5-step resolution so speech never silently no-ops when any usable
    /// voice exists:
    /// 1. Use the caller-supplied `language` if given, else detect the
    ///    dominant language of `text` (fallback "en").
    /// 2. An explicit `voiceID` is honored only if it's installed AND its
    ///    language matches that language — otherwise it yields to
    ///    language routing.
    /// 3. Best-ranked installed voice for the language.
    /// 4. A system voice for a reasonable BCP-47 locale guess for that language.
    /// 5. The existing en fallback chain (best-ranked en voice, else en-US).
    private static func resolveVoice(text: String, voiceID: String?, language: String? = nil) -> AVSpeechSynthesisVoice? {
        let lang = language ?? dominantLanguageCode(of: text) ?? "en"

        if let voiceID,
           let explicit = AVSpeechSynthesisVoice(identifier: voiceID),
           primarySubtag(of: explicit.language) == lang {
            return explicit
        }

        let ranked = rankedVoices(languagePrefix: lang)
        if let top = ranked.first {
            // Chinese has regional voices for two scripts (zh-CN/zh-SG write
            // simplified, zh-TW/zh-HK/zh-MO traditional). Within the best
            // quality tier, prefer the voice matching the text's script —
            // otherwise simplified text can land on the zh-TW voice purely
            // because "Meijia" sorts before "Tingting". Quality still wins
            // over region: a premium voice of either region beats a compact
            // one of the "right" region.
            if lang == "zh" {
                let preferredTags = preferredChineseTags(for: text)
                let topTier = ranked.prefix { $0.quality == top.quality }
                if let regional = topTier.first(where: { preferredTags.contains($0.language) }) {
                    return regional
                }
            }
            return top
        }

        if let byLocale = AVSpeechSynthesisVoice(language: fallbackBCP47(lang)) {
            return byLocale
        }

        if let en = rankedVoices().first {
            return en
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// BCP-47 tags of the Chinese-voice regions matching the script `text` is
    /// written in, best guesses first. Decided by a recognizer constrained to
    /// simplified vs. traditional, so the mixed-content misfires that plague
    /// open-ended detection can't happen here.
    private static func preferredChineseTags(for text: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        if recognizer.dominantLanguage == .traditionalChinese {
            return ["zh-TW", "zh-HK", "zh-MO"]
        }
        return ["zh-CN", "zh-SG"]
    }

    /// A reasonable BCP-47 locale guess for a bare language subtag, used only
    /// as a last-resort system-voice lookup before falling back to en.
    private static func fallbackBCP47(_ lang: String) -> String {
        switch lang {
        case "zh": return "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "en": return "en-US"
        default: return "\(lang)-\(lang.uppercased())"
        }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Default"
        @unknown default: return "Unknown"
        }
    }

    /// Every installed voice (any language) passing the quality exclusions,
    /// for the Settings picker. Sorted language ascending, then quality desc,
    /// then name ascending. Display name is "Name (lang) · Quality", e.g.
    /// "Tingting (zh-CN) · Default".
    private static func loadAvailableVoices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter(passesQualityExclusions)
            .sorted { lhs, rhs in
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                let lhsRank = qualityRank(lhs.quality)
                let rhsRank = qualityRank(rhs.quality)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs.name < rhs.name
            }
            .map { voice in
                let quality = qualityLabel(voice.quality)
                return Voice(
                    id: voice.identifier,
                    name: "\(voice.name) (\(voice.language)) · \(quality)",
                    quality: quality
                )
            }
    }

    // MARK: - speechText(fromMarkdown:maxChars:)

    /// Converts a markdown-ish Claude reply into plain, speakable text:
    /// fenced code blocks collapse to "code omitted" (localized to Chinese
    /// when the INPUT text's dominant language is Chinese), inline markdown
    /// syntax is stripped, whitespace is collapsed, and the result is
    /// truncated to `maxChars` at a sentence boundary where possible.
    static func speechText(fromMarkdown text: String, maxChars: Int) -> String {
        spokenReply(fromMarkdown: text, maxChars: maxChars).text
    }

    /// Same conversion, but also reports the language the localized phrases
    /// were chosen for, so the caller can hand it to
    /// `speak(_:voiceID:rate:language:)` and the voice can never disagree with
    /// the phrases (re-detecting on the OUTPUT can flip: "好的。 code omitted"
    /// reads as English once the injected phrase outweighs the prose).
    static func spokenReply(fromMarkdown text: String, maxChars: Int) -> (text: String, language: String) {
        var working = text

        // Fenced code blocks (```...```) -> placeholder, BEFORE the language
        // is detected: the ASCII identifiers inside a fence would otherwise
        // swamp the letter counts and misfile a Chinese reply as English.
        // U+FFFC (object replacement) carries no letters, so the fences
        // contribute nothing to the decision; the localized phrase is
        // substituted in afterwards.
        let codePlaceholder = "\u{FFFC}"
        working = replacing(pattern: "```[\\s\\S]*?```", in: working, with: codePlaceholder)

        let inputLanguage = dominantLanguageCode(of: working) ?? "en"
        let codeOmittedPhrase = inputLanguage == "zh" ? "（代码已省略）" : "code omitted"
        let truncatedSuffix = inputLanguage == "zh" ? "……回复已截断。" : "… reply truncated."

        working = working.replacingOccurrences(of: codePlaceholder, with: codeOmittedPhrase)

        // Inline code spans `code` -> code (strip backticks, keep content)
        working = replacing(pattern: "`([^`]*)`", in: working, with: "$1")

        // Markdown links/images: [text](url) -> text ; ![alt](url) -> alt
        working = replacing(pattern: "!?\\[([^\\]]*)\\]\\([^)]*\\)", in: working, with: "$1")

        // Heading markers at line start: "# ", "## ", etc.
        working = replacing(pattern: "(?m)^\\s{0,3}#{1,6}\\s+", in: working, with: "")

        // Blockquote markers at line start
        working = replacing(pattern: "(?m)^\\s{0,3}>\\s?", in: working, with: "")

        // Emphasis / bold / strikethrough markers: *, **, _, __, ~~
        working = replacing(pattern: "\\*\\*([^*]+)\\*\\*", in: working, with: "$1")
        working = replacing(pattern: "\\*([^*]+)\\*", in: working, with: "$1")
        working = replacing(pattern: "__([^_]+)__", in: working, with: "$1")
        working = replacing(pattern: "_([^_]+)_", in: working, with: "$1")
        working = replacing(pattern: "~~([^~]+)~~", in: working, with: "$1")

        // Leftover stray markdown punctuation runs (list bullets, remaining # * > _)
        working = replacing(pattern: "(?m)^\\s{0,3}[-*+]\\s+", in: working, with: "")
        working = replacing(pattern: "[#*_>`]", in: working, with: "")

        // Collapse whitespace
        working = replacing(pattern: "\\s+", in: working, with: " ")
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)

        guard maxChars > 0, working.count > maxChars else {
            return (working, inputLanguage)
        }

        let hardLimit = working.index(working.startIndex, offsetBy: maxChars)
        let window = String(working[working.startIndex..<hardLimit])

        // Look for the last sentence-ending punctuation within the window —
        // including the full-width terminators CJK prose actually ends
        // sentences with (an ASCII period effectively never appears there).
        let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        var cutIndex: String.Index? = nil
        var searchIndex = window.endIndex
        while searchIndex > window.startIndex {
            let prev = window.index(before: searchIndex)
            if sentenceEnders.contains(window[prev]) {
                cutIndex = searchIndex
                break
            }
            searchIndex = prev
        }

        let truncated: String
        if let cutIndex, cutIndex > window.startIndex {
            truncated = String(window[window.startIndex..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            truncated = window.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Chinese doesn't space-separate sentences — join the suffix directly.
        let joiner = inputLanguage == "zh" ? "" : " "
        return (truncated + joiner + truncatedSuffix, inputLanguage)
    }

    private static func replacing(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            self.onFinished?()
        }
    }
}
