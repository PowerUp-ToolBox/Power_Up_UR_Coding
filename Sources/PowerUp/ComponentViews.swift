import SwiftUI
import AppKit

// MARK: - Theme
//
// One place for the whole "gamer-meets-developer" look: near-black blue
// backdrop, a single electric-blue accent, hairline white borders.

enum Theme {

    // Accent + surfaces
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965)   // #3B82F6
    static let accentBright = Color(red: 0.447, green: 0.639, blue: 1.0)
    static let accentDeep = Color(red: 0.118, green: 0.318, blue: 0.769)

    static let bgTop = Color(red: 0.043, green: 0.055, blue: 0.094)
    static let bgMid = Color(red: 0.027, green: 0.043, blue: 0.098)
    static let bgBottom = Color(red: 0.012, green: 0.016, blue: 0.035)

    static let cardFill = Color.white.opacity(0.045)
    static let cardFillRaised = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.06)

    // Text
    static let textPrimary = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.34)

    // Semantic
    static let danger = Color(red: 1.0, green: 0.29, blue: 0.32)
    static let success = Color(red: 0.20, green: 0.85, blue: 0.52)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.15)
    static let violet = Color(red: 0.65, green: 0.35, blue: 1.0)

    // Type
    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let badge = Font.system(size: 9.5, weight: .bold, design: .rounded)

    static let accentGradient = LinearGradient(
        colors: [accentBright, accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Status

    /// Mirrors the DualSense light-bar colour for each app status.
    static func color(for status: AppStatus) -> Color {
        switch status {
        case .noController: return Color.white.opacity(0.35)
        case .idle: return accent
        case .listening: return danger
        case .thinking: return amber
        case .speaking: return violet
        }
    }

    static func symbol(for status: AppStatus) -> String {
        switch status {
        case .noController: return "exclamationmark.triangle.fill"
        case .idle: return "checkmark.circle.fill"
        case .listening: return "mic.fill"
        case .thinking: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// Statuses that deserve a live, breathing indicator.
    static func isLive(_ status: AppStatus) -> Bool {
        switch status {
        case .listening, .thinking, .speaking: return true
        case .idle, .noController: return false
        }
    }

    // MARK: Actions

    static func symbol(for action: ControllerAction) -> String {
        switch action {
        case .none: return "minus"
        case .pushToTalk: return "mic.fill"
        case .sendPrompt: return "text.bubble.fill"
        case .approve: return "checkmark.circle.fill"
        case .reject: return "xmark.circle.fill"
        case .interrupt: return "stop.circle.fill"
        case .stopSpeaking: return "speaker.slash.fill"
        case .replayLastReply: return "arrow.counterclockwise"
        case .toggleTTS: return "speaker.wave.2.fill"
        case .newSession: return "plus.bubble.fill"
        case .showWindow: return "macwindow"
        case .cycleModel: return "cpu"
        case .cycleEffort: return "gauge"
        case .cyclePermissionMode: return "hand.raised.fill"
        case .toggleControlMode: return "antenna.radiowaves.left.and.right"
        case .pushToTalkDraft: return "mic.badge.plus"
        case .sendDraft: return "paperplane.fill"
        }
    }

    /// Short, human label for a mapped action — quotes the text of a fixed prompt.
    static func label(for action: ControllerAction) -> String {
        if case .sendPrompt(let prompt) = action {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Send Prompt…" : "“\(trimmed)”"
        }
        return action.displayName
    }

    // MARK: Buttons

    /// `ControllerButton.symbolName` is the preferred glyph, but a couple of the
    /// gamepad symbols are missing on some systems — resolve once and substitute
    /// something sensible so a legend row never renders blank.
    private static let buttonSymbols: [ControllerButton: String] = {
        var resolved: [ControllerButton: String] = [:]
        for button in ControllerButton.allCases {
            let preferred = button.symbolName
            let exists = NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil
            resolved[button] = exists ? preferred : fallbackButtonSymbol(for: button)
        }
        return resolved
    }()

    static func symbol(for button: ControllerButton) -> String {
        buttonSymbols[button] ?? "gamecontroller.fill"
    }

    private static func fallbackButtonSymbol(for button: ControllerButton) -> String {
        switch button {
        case .l3: return "l.joystick.press.down.fill"
        case .r3: return "r.joystick.press.down.fill"
        case .cross: return "xmark.circle"
        case .circle: return "circle.circle"
        case .square: return "square.circle"
        case .triangle: return "triangle.circle"
        case .dpadUp: return "arrow.up.circle"
        case .dpadDown: return "arrow.down.circle"
        case .dpadLeft: return "arrow.left.circle"
        case .dpadRight: return "arrow.right.circle"
        case .touchpad: return "hand.point.up.left"
        case .ps: return "house.circle"
        default: return "gamecontroller.fill"
        }
    }

    // MARK: Tools

    static func toolSymbol(for name: String) -> String {
        switch name.lowercased() {
        case "read", "notebookread": return "doc.text"
        case "edit", "write", "multiedit", "notebookedit": return "pencil"
        case "bash", "bashoutput", "killshell": return "terminal"
        case "grep", "glob", "search": return "magnifyingglass"
        case "webfetch", "websearch": return "globe"
        case "task", "agent": return "sparkles"
        case "todowrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    // MARK: Formatting

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func costString(_ usd: Double) -> String {
        String(format: usd >= 1 ? "$%.2f" : "$%.4f", usd)
    }
}

// MARK: - Background

/// Near-black blue gradient with two very soft coloured glows.
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.bgTop, Theme.bgMid, Theme.bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.accent.opacity(0.16), .clear],
                center: .init(x: 0.08, y: 0.0),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Theme.violet.opacity(0.12), .clear],
                center: .init(x: 1.0, y: 1.0),
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card styling

struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 14
    var fill: Color = Theme.cardFill
    var stroke: Color = Theme.cardStroke

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

extension View {
    func powerUpCard(padding: CGFloat = 14,
                     cornerRadius: CGFloat = 14,
                     fill: Color = Theme.cardFill,
                     stroke: Color = Theme.cardStroke) -> some View {
        modifier(CardModifier(padding: padding,
                              cornerRadius: cornerRadius,
                              fill: fill,
                              stroke: stroke))
    }
}

/// Small all-caps section header used across the sidebar.
struct SectionLabel: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(1.1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Status dot & pill

/// A coloured dot that softly breathes while the app is doing something.
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.1, height: size * 2.1)
                .scaleEffect(pulsing && pulse ? 1.15 : 0.65)
                .opacity(pulsing ? (pulse ? 0.0 : 0.7) : 0.0)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.9), radius: pulsing ? 5 : 2)
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
        .onAppear { pulse = pulsing }
        .onChange(of: pulsing) { _, newValue in pulse = newValue }
    }
}

/// Toolbar pill showing the current `AppStatus`.
struct StatusPill: View {
    let status: AppStatus

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: Theme.color(for: status), pulsing: Theme.isLive(status), size: 7)
            Text(status.label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.color(for: status).opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.color(for: status).opacity(0.35), lineWidth: 1)
        )
        .help(status.label)
    }
}

// MARK: - Session chip

/// Small monospaced capsule used in the top info bar to surface a live session
/// setting (model / effort / permission mode / cost) at a glance.
struct SessionChip: View {
    let symbol: String
    let label: String
    var tint: Color = Theme.accentBright
    /// Tooltip; defaults to the label itself.
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(Theme.monoSmall)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.32), lineWidth: 1))
        .fixedSize()
        .help(help ?? label)
    }
}

// MARK: - Warning banner

/// Compact amber banner for a condition the user needs to act on to unblock a
/// feature (e.g. Remote Control targeting an app/frontmost without
/// Accessibility granted). Deliberately louder than `SessionChip` — this is
/// meant to be noticed, not just glanced at.
struct WarningBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.amber.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Battery

/// Little battery pill: outline, proportional fill, percentage, charging bolt.
struct BatteryGauge: View {
    let level: Float?
    var isCharging: Bool = false

    private var clamped: CGFloat {
        guard let level else { return 0 }
        return CGFloat(min(max(level, 0), 1))
    }

    private var tint: Color {
        if isCharging { return Theme.success }
        switch clamped {
        case ..<0.15: return Theme.danger
        case ..<0.35: return Theme.amber
        default: return Theme.success
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 26, height: 13)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(tint)
                            .frame(width: max(2, 22 * clamped), height: 9)
                            .padding(.leading, 2)
                            .opacity(level == nil ? 0 : 1)
                    }
                Capsule()
                    .fill(Theme.textTertiary)
                    .frame(width: 2, height: 5)
            }
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.success)
            }
            Text(percentText)
                .font(Theme.monoSmall)
                .foregroundStyle(level == nil ? Theme.textTertiary : Theme.textSecondary)
        }
        .help(isCharging ? "Controller is charging" : "Controller battery")
    }

    private var percentText: String {
        guard let level else { return "--%" }
        return "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Empty states

/// Shown when no DualSense is paired — plain-English pairing steps.
struct PairingHintCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Pair your controller", symbol: "dot.radiowaves.left.and.right")
            step(1, "On the controller, hold the PS button and the Create button (left of the touchpad) until the light bar flashes.")
            step(2, "Open System Settings → Bluetooth on your Mac.")
            step(3, "Click Connect next to “DualSense Wireless Controller”.")
            Text("A USB-C cable works too — plug it in and it connects instantly.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .powerUpCard(fill: Theme.accent.opacity(0.07), stroke: Theme.accent.opacity(0.22))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accentBright)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Centred call-to-action shown when no project folder has been chosen.
struct NoProjectCard: View {
    let chooseAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accentBright)
            }
            .shadow(color: Theme.accent.opacity(0.35), radius: 24)

            VStack(spacing: 6) {
                Text("Choose a project folder")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("PowerUp runs Claude Code inside the folder you pick. Everything you say or type goes to a session started there.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Button(action: chooseAction) {
                Label("Choose Folder…", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
        }
        .padding(30)
        .frame(maxWidth: 460)
        .powerUpCard(padding: 12, cornerRadius: 20, fill: Theme.cardFill, stroke: Theme.cardStroke)
    }
}

/// Friendly placeholder for an empty transcript.
struct EmptyTranscriptCard: View {
    let pushToTalkHint: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accentBright.opacity(0.8))
            Text("Ready when you are")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(hintText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .powerUpCard(padding: 8, cornerRadius: 18)
    }

    private var hintText: String {
        if let pushToTalkHint {
            return "Hold \(pushToTalkHint) on the controller and speak, or type a message below."
        }
        return "Type a message below, or map a button to Push to Talk in Settings."
    }
}

// MARK: - Mapping legend

struct MappingLegendRow: View {
    /// Which half of the pair gets the strong line: the action it performs
    /// (legend reading) or the physical button (cheat-sheet reading).
    enum Emphasis { case action, button }

    let button: ControllerButton
    let action: ControllerAction
    var emphasis: Emphasis = .action

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: Theme.symbol(for: button))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isUnmapped ? Theme.textTertiary : Theme.accentBright)
                .frame(width: 18, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if action.isHoldAction {
                HoldBadge()
            }
        }
        .padding(.vertical, 3)
        .help("\(button.displayName) → \(actionText)")
    }

    private var isUnmapped: Bool { action == .none }

    /// An unmapped button reads as a dash rather than the word "None".
    private var actionText: String {
        isUnmapped ? "—" : Theme.label(for: action)
    }

    private var primaryText: String {
        emphasis == .action ? actionText : button.displayName
    }

    private var secondaryText: String {
        emphasis == .action ? button.displayName : actionText
    }
}

/// Marks an action that records while the button is held down.
struct HoldBadge: View {
    var body: some View {
        Text("HOLD")
            .font(Theme.badge)
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.danger.opacity(0.16)))
    }
}

// MARK: - Controls card row

/// One line of the slim sidebar "Controls" card: the glyph(s) of every button
/// currently mapped to an action, followed by a plain-English label. Several
/// buttons mapped to the same action share a single row.
struct ControlHintRow: View {
    let buttons: [ControllerButton]
    let label: String

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            HStack(spacing: 3) {
                ForEach(buttons) { button in
                    Image(systemName: Theme.symbol(for: button))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accentBright)
                }
            }
            .frame(minWidth: 18, alignment: .leading)

            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(helpText)
    }

    private var helpText: String {
        let names = buttons.map(\.displayName).joined(separator: " or ")
        return names.isEmpty ? label : "\(names) → \(label)"
    }
}

// MARK: - All buttons cheat sheet

/// Every controller button and what it currently does — opened from the
/// Controls card. Reads the mapping straight from `ConfigStore` (sheets inherit
/// the presenting view's environment) so it is never showing a stale snapshot.
@MainActor
struct AllButtonsSheet: View {
    @EnvironmentObject private var configStore: ConfigStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ControllerButton.allCases) { button in
                        MappingLegendRow(button: button,
                                         action: configStore.config.mapping[button] ?? .none,
                                         emphasis: .button)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("Edit in Settings → Buttons")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 420, height: 520)
        .background(AppBackground())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accentBright)
            VStack(alignment: .leading, spacing: 1) {
                Text("Controller Buttons")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Every button on the pad and what it does right now")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Transcript

/// Renders one transcript entry in the style appropriate to its kind.
struct TranscriptBubble: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            UserBubble(text: entry.text, date: entry.date)
        case .assistant:
            AssistantBubble(text: entry.text, date: entry.date)
        case .tool:
            ToolRow(text: entry.text)
        case .system:
            CenteredNote(text: entry.text, symbol: "info.circle", tint: Theme.textTertiary)
        case .error:
            CenteredNote(text: entry.text, symbol: "exclamationmark.triangle.fill", tint: Theme.danger)
        }
    }
}

struct UserBubble: View {
    let text: String
    let date: Date

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accentGradient)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: Theme.accent.opacity(0.28), radius: 10, y: 3)
                Text(Theme.timeString(date))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 560, alignment: .trailing)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 3) {
                Text(Theme.markdown(text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.cardFillRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    )
                Text(Theme.timeString(date))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 20)
        }
    }
}

/// Small Claude glyph next to assistant replies.
struct AssistantAvatar: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.16))
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accentBright)
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
    }
}

/// Compact monospaced row for a tool call ("Edit — src/main.py").
struct ToolRow: View {
    let text: String

    private var parts: (name: String, detail: String?) {
        let separators = [" — ", " - ", ": "]
        for sep in separators {
            if let range = text.range(of: sep) {
                let name = String(text[text.startIndex..<range.lowerBound])
                let detail = String(text[range.upperBound...])
                return (name, detail.isEmpty ? nil : detail)
            }
        }
        return (text, nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.toolSymbol(for: parts.name))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accentBright.opacity(0.9))
                .frame(width: 14)
            Text(parts.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            if let detail = parts.detail {
                Text(detail)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .padding(.leading, 33)
        .padding(.trailing, 20)
    }
}

/// Centred caption used for system notes and errors.
struct CenteredNote: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(tint == Theme.danger ? 0.12 : 0.05))
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

/// Three dots that breathe while Claude is streaming.
struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: 5, height: 5)
                    .opacity(animating ? 1.0 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// The in-progress assistant reply, streamed token by token.
struct LiveAssistantBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 6) {
                Text(Theme.markdown(text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    TypingIndicator()
                    Text("writing…")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
            )
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 20)
        }
    }
}

// MARK: - Push to talk

/// Big circular mic button/indicator. Glows red and shows the live partial
/// transcript while push-to-talk is held.
struct PTTIndicator: View {
    let isActive: Bool
    /// The active hold dictates into the prompt box rather than sending.
    var isDraft: Bool = false
    /// The active draft hold types into the remote session instead of the box.
    var isRemoteDraft: Bool = false
    let partialTranscript: String
    var hint: String?

    @State private var ring = false

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .stroke(Theme.danger.opacity(0.55), lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(ring ? 1.55 : 0.9)
                    .opacity(ring ? 0.0 : 0.8)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: ring)
            }
            Circle()
                .fill(isActive
                      ? AnyShapeStyle(LinearGradient(colors: [Theme.danger, Theme.danger.opacity(0.65)],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Theme.cardFillRaised))
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().strokeBorder(isActive ? Color.white.opacity(0.25) : Theme.cardStroke,
                                          lineWidth: 1)
                )
                .shadow(color: isActive ? Theme.danger.opacity(0.75) : .clear, radius: 16)
            Image(systemName: isActive ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Theme.textSecondary)
                .symbolEffectCompat(isActive)
        }
        .frame(width: 52, height: 52)
        .onAppear { ring = isActive }
        .onChange(of: isActive) { _, newValue in ring = newValue }
        .help(helpText)
        .accessibilityLabel(isActive ? "Listening" : "Push to talk")
    }

    private var helpText: String {
        if isActive {
            if partialTranscript.isEmpty {
                if isRemoteDraft { return "Listening… your words will be typed into the remote session." }
                return isDraft ? "Listening… your words go to the prompt box." : "Listening…"
            }
            return partialTranscript
        }
        if let hint { return "Hold \(hint) on the controller to talk" }
        return "Map a controller button to Push to Talk in Settings"
    }
}

/// Banner above the composer showing what the mic is hearing right now.
struct PTTTranscriptBanner: View {
    let partialTranscript: String
    /// A draft hold never sends — its empty-transcript copy must not claim it will.
    var isDraft: Bool = false
    /// The draft hold types into the remote session instead of the prompt box.
    var isRemoteDraft: Bool = false

    private var emptyHint: String {
        if isRemoteDraft {
            return "Listening… release to type the text into the remote session (nothing is sent)."
        }
        return isDraft
            ? "Listening… release to drop the text in the prompt box."
            : "Listening… speak now, release to send."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(partialTranscript.isEmpty ? emptyHint : partialTranscript)
                .font(.system(size: 12.5, weight: partialTranscript.isEmpty ? .regular : .medium))
                .foregroundStyle(partialTranscript.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.default, value: partialTranscript)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.danger.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Theme.danger.opacity(0.25), radius: 12)
    }
}

// MARK: - Helpers

extension Theme {
    /// Renders light markdown (bold/italic/inline code) while keeping line breaks.
    static func markdown(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}

private extension View {
    /// Gentle scale "pulse" for the mic glyph; plain no-op styling elsewhere.
    @ViewBuilder
    func symbolEffectCompat(_ active: Bool) -> some View {
        self.scaleEffect(active ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.25), value: active)
    }
}
