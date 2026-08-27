import SwiftUI
import AppKit

// MARK: - MainView

/// The app's single window: a full-width top info bar, a slim Controls
/// sidebar, the transcript, and the composer.
///
/// Everything that changes while you play — controller battery, status, model /
/// effort / permission mode, cost — lives in the top info bar, built from small
/// subviews that each declare the environment objects they read. That is
/// deliberate: values handed down through `init` from a parent that doesn't
/// observe the same object go stale, and toolbar item closures have their own
/// refresh quirks, which is why the chips moved out of `.toolbar` and into the
/// content hierarchy.
struct MainView: View {

    @State private var showsAllButtons = false

    var body: some View {
        VStack(spacing: 0) {
            TopInfoBar()
            RemoteAXWarningBanner()

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            HStack(spacing: 0) {
                SidebarPane(showsAllButtons: $showsAllButtons)
                    .frame(width: 240)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .ignoresSafeArea(edges: .bottom)
                ConversationPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsAllButtons) {
            AllButtonsSheet()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProjectPickerButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                InterruptButton()
                NewSessionButton()
                SettingsGearButton()
            }
        }
    }
}

// MARK: - Top info bar

/// Full-width strip under the title bar: controller, status, session chips,
/// cost. Each group is its own view with its own `@EnvironmentObject`
/// declarations so a change to any one service re-renders exactly that chip.
@MainActor
private struct TopInfoBar: View {
    var body: some View {
        HStack(spacing: 10) {
            ModeChip()
            ControllerInfoChip()
            BarStatusPill()

            Spacer(minLength: 8)

            ModelChip()
            EffortChip()
            PermissionChip()
            CostChip()
        }
        .frame(maxWidth: .infinity)
        .powerUpCard(padding: 9, cornerRadius: 13, fill: Theme.cardFill, stroke: Theme.cardStroke)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }
}

/// Amber warning shown directly under the top info bar when Remote Control is
/// aimed at a keystroke-injection target (Terminal/app or Frontmost) without
/// Accessibility granted — the one condition where a controller press or a
/// finished dictation would otherwise silently type nowhere. Reads
/// `RemoteControlService.axTrusted` directly so it appears and disappears the
/// instant a grant is made (or revoked) in Settings, with no user action
/// needed to refresh it. Not shown for the cmux target, which needs no
/// permission at all.
@MainActor
private struct RemoteAXWarningBanner: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var remote: RemoteControlService

    private var isInjectionTarget: Bool {
        let kind = configStore.config.remoteTargetKind
        return kind == "app" || kind == "frontmost"
    }

    private var shouldShow: Bool {
        configStore.config.controlMode == "remote" && isInjectionTarget && !remote.axTrusted
    }

    var body: some View {
        if shouldShow {
            WarningBanner(text: "Remote typing needs Accessibility — use cmux or grant access in Settings → Remote")
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }
}

/// Controller name, connection dot and battery — reads `ControllerService`
/// directly so the 60-second battery poll and connect/disconnect events land
/// here without anything having to pass them down.
@MainActor
private struct ControllerInfoChip: View {
    @EnvironmentObject private var controller: ControllerService

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(controller.isConnected ? Theme.accentBright : Theme.textTertiary)

            StatusDot(color: controller.isConnected ? Theme.success : Theme.textTertiary,
                      pulsing: false,
                      size: 6)

            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(controller.isConnected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if controller.isConnected {
                BatteryGauge(level: controller.batteryLevel, isCharging: controller.isCharging)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(helpText)
    }

    private var name: String {
        if let name = controller.controllerName, !name.isEmpty { return name }
        return controller.isConnected ? "Controller" : "No controller"
    }

    private var helpText: String {
        guard controller.isConnected else {
            return "No controller connected — see the pairing steps in the sidebar"
        }
        return controller.isDualSense ? "\(name) (DualSense)" : name
    }
}

/// First chip in the bar: which control mode is active, and — in Remote —
/// which target the controller/voice input is currently aimed at. Reads
/// `RemoteControlService` directly so a cmux workspace refresh (used to
/// resolve "Auto") lands here live.
@MainActor
private struct ModeChip: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var remote: RemoteControlService

    private var isRemote: Bool { configStore.config.controlMode == "remote" }

    var body: some View {
        SessionChip(symbol: isRemote ? "antenna.radiowaves.left.and.right" : "desktopcomputer",
                    label: label,
                    tint: isRemote ? Theme.violet : Theme.success,
                    help: label)
    }

    private var label: String {
        guard isRemote else { return "Built-in" }
        switch configStore.config.remoteTargetKind {
        case "cmux": return "Remote · cmux ws \(cmuxWorkspaceLabel)"
        case "app": return "Remote · \(appLabel)"
        default: return "Remote · frontmost"
        }
    }

    /// The explicit workspace if one is pinned, else whichever workspace cmux
    /// currently reports as `[selected]` — mirrors the "Auto" resolution
    /// `RemoteControlService.sendText` performs at send time.
    private var cmuxWorkspaceLabel: String {
        let ref = configStore.config.remoteCmuxWorkspace
            ?? remote.cmuxWorkspaces.first(where: { $0.selected })?.ref
        guard let ref, !ref.isEmpty else { return "?" }
        if let colon = ref.lastIndex(of: ":") {
            return String(ref[ref.index(after: colon)...])
        }
        return ref
    }

    private var appLabel: String {
        guard let bundleID = configStore.config.remoteAppBundleID, !bundleID.isEmpty else {
            return "app"
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        return bundleID
    }
}

@MainActor
private struct BarStatusPill: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        StatusPill(status: appState.status)
    }
}

/// Model chip. `config.model` wins whenever it is an explicit alias, so a
/// controller-driven Cycle Model press shows up instantly (optimistic); only
/// when the config says "default" do we fall back to whatever the CLI reported.
@MainActor
private struct ModelChip: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var claude: ClaudeService

    var body: some View {
        SessionChip(symbol: "cpu", label: label, help: "Model: \(label)")
    }

    private var label: String {
        let configured = configStore.config.model
        if configured != "default", !configured.isEmpty { return configured }
        if let reported = claude.modelName, !reported.isEmpty { return reported }
        return "default"
    }
}

@MainActor
private struct EffortChip: View {
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        let effort = configStore.config.effort
        SessionChip(symbol: "gauge",
                    label: effort,
                    tint: Theme.amber,
                    help: "Thinking effort: \(effort)")
    }
}

/// Permission mode is only known when PowerUp runs the session itself — in
/// Remote mode the cycle-permission-mode button still fires (Shift+Tab into
/// the target), but PowerUp has no way to read back what mode that left the
/// session in, so the chip is honest about it rather than showing a stale guess.
@MainActor
private struct PermissionChip: View {
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        if configStore.config.controlMode == "remote" {
            SessionChip(symbol: "hand.raised.fill",
                        label: "—",
                        tint: Theme.textTertiary,
                        help: "Permission mode isn't visible in Remote Control mode")
        } else {
            let mode = configStore.config.permissionMode
            SessionChip(symbol: "hand.raised.fill",
                        label: mode,
                        tint: mode == "bypassPermissions" ? Theme.danger : Theme.violet,
                        help: mode == "bypassPermissions"
                            ? "Permissions: bypassPermissions — Claude auto-approves everything"
                            : "Permissions: \(mode)")
        }
    }
}

@MainActor
private struct CostChip: View {
    @EnvironmentObject private var claude: ClaudeService

    var body: some View {
        SessionChip(symbol: "sum",
                    label: Theme.costString(claude.totalCostUSD),
                    tint: Theme.textSecondary,
                    help: "Total cost of this session so far")
    }
}

// MARK: - Toolbar pieces

@MainActor
private struct ProjectPickerButton: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configStore: ConfigStore

    var body: some View {
        Button {
            appState.chooseProjectDirectory()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasProject ? "folder.fill" : "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasProject ? Theme.accentBright : Theme.amber)
                Text(folderName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: 220)
        }
        .help(configStore.config.projectDir ?? "Choose the folder Claude Code should work in")
    }

    private var hasProject: Bool { configStore.config.projectDir != nil }

    private var folderName: String {
        guard let path = configStore.config.projectDir, !path.isEmpty else {
            return "Choose Project Folder…"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

@MainActor
private struct InterruptButton: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var claude: ClaudeService
    @EnvironmentObject private var configStore: ConfigStore

    /// In remote mode `claude.state` is always `.stopped` (no process of ours
    /// runs), so it can't gate the button: `remoteTurnActive` marks a turn in
    /// flight, and the button stays enabled even when idle — Escape is harmless
    /// at an idle prompt, and it's the window's only interrupt affordance there.
    private var isRemote: Bool { configStore.config.controlMode == "remote" }

    var body: some View {
        let engaged = claude.state == .working || (isRemote && appState.remoteTurnActive)
        Group {
            if engaged {
                Button { appState.interruptClaude() } label: {
                    Label("Interrupt", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
            } else {
                Button { appState.interruptClaude() } label: {
                    Label("Interrupt", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!isRemote)
            }
        }
        .help(isRemote ? "Send Escape to the remote session to stop its current turn"
                       : "Stop what Claude is doing right now")
    }
}

@MainActor
private struct NewSessionButton: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            appState.newSession()
        } label: {
            Label("New Session", systemImage: "plus.bubble")
        }
        .buttonStyle(.bordered)
        .help("Start a fresh Claude session with an empty context")
    }
}

private struct SettingsGearButton: View {
    var body: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape.fill")
        }
        .help("Open PowerUp settings")
    }
}

// MARK: - Sidebar

@MainActor
private struct SidebarPane: View {
    @EnvironmentObject private var controller: ControllerService
    @Binding var showsAllButtons: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ControlsCard(showsAllButtons: $showsAllButtons)

                if !controller.isConnected {
                    PairingHintCard()
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.opacity(0.22))
    }
}

/// The six "core controls", derived live from the mapping by reverse lookup.
private struct ControlHint: Identifiable {
    let label: String
    let buttons: [ControllerButton]
    var id: String { label }
}

/// Slim sidebar card: only the handful of actions you actually reach for while
/// working, each shown with the glyph(s) of whatever button(s) currently map to
/// it. A row disappears entirely when nothing is mapped to its action.
@MainActor
private struct ControlsCard: View {
    @EnvironmentObject private var configStore: ConfigStore
    @Binding var showsAllButtons: Bool

    /// Order is fixed and meaningful: dictate → send → talk, then the three
    /// session cycles.
    private static let order: [(action: ControllerAction, label: String)] = [
        (.pushToTalkDraft, "Dictate to prompt box (hold)"),
        (.sendDraft, "Send prompt box"),
        (.pushToTalk, "Talk to Claude (hold)"),
        (.cycleModel, "Change model"),
        (.cycleEffort, "Change effort"),
        (.cyclePermissionMode, "Change permission mode")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Controls", symbol: "gamecontroller.fill")

            if hints.isEmpty {
                Text("None of the main actions are mapped yet. Open Settings → Buttons to assign them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hints) { hint in
                        ControlHintRow(buttons: hint.buttons, label: hint.label)
                    }
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            allButtonsButton
        }
        .powerUpCard(padding: 12)
    }

    private var allButtonsButton: some View {
        Button {
            showsAllButtons = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                Text("All Buttons…")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.accentBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("See every controller button and what it does")
    }

    /// Reverse lookup: several buttons may share one action, and their glyphs
    /// are joined into a single row.
    private var hints: [ControlHint] {
        let mapping = configStore.config.mapping
        return Self.order.compactMap { entry in
            let buttons = ControllerButton.allCases.filter { mapping[$0] == entry.action }
            guard !buttons.isEmpty else { return nil }
            return ControlHint(label: entry.label, buttons: buttons)
        }
    }
}

// MARK: - Conversation

@MainActor
private struct ConversationPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configStore: ConfigStore

    /// Remote mode needs no project folder — PowerUp runs no session of its
    /// own there, and hiding the transcript would hide the hook read-back the
    /// mode exists to show.
    private var isRemote: Bool { configStore.config.controlMode == "remote" }

    var body: some View {
        VStack(spacing: 0) {
            if configStore.config.projectDir == nil && !isRemote {
                VStack {
                    Spacer(minLength: 0)
                    NoProjectCard { appState.chooseProjectDirectory() }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                TranscriptScrollView()
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            ComposerBar()
        }
    }
}

@MainActor
private struct TranscriptScrollView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var claude: ClaudeService

    private static let bottomAnchor = "powerup.transcript.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.transcript.isEmpty && !showsLiveReply {
                        EmptyTranscriptCard(pushToTalkHint: pushToTalkButtonName(in: configStore.config.mapping))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }

                    ForEach(appState.transcript) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }

                    if showsLiveReply {
                        LiveAssistantBubble(text: appState.liveAssistantText)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: appState.transcript.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: appState.liveAssistantText) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsLiveReply: Bool {
        claude.state == .working && !appState.liveAssistantText.isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

// MARK: - Composer

@MainActor
private struct ComposerBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var speech: SpeechService

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.isPTTActive {
                PTTTranscriptBanner(partialTranscript: speech.partialTranscript,
                                    isDraft: appState.isDraftDictation,
                                    isRemoteDraft: appState.draftDictationTargetsRemote,
                                    recognitionLanguage: recognitionLanguageWarning)
            }

            HStack(alignment: .center, spacing: 12) {
                PTTIndicator(isActive: appState.isPTTActive,
                             isDraft: appState.isDraftDictation,
                             isRemoteDraft: appState.draftDictationTargetsRemote,
                             partialTranscript: speech.partialTranscript,
                             hint: pushToTalkButtonName(in: configStore.config.mapping))
                inputField
                sendButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
        .animation(.easeInOut(duration: 0.2), value: appState.isPTTActive)
    }

    /// Non-nil (a display name) when speech recognition is set to a
    /// non-English language — the #1 cause of "my dictation is garbage"
    /// reports is a locale that doesn't match what the user speaks, so it's
    /// surfaced right in the listening banner.
    private var recognitionLanguageWarning: String? {
        let localeID = configStore.config.localeID
        guard !localeID.lowercased().hasPrefix("en") else { return nil }
        return Locale.current.localizedString(forIdentifier: localeID) ?? localeID
    }

    /// Bound to `AppState.draftText` (not a local `@State`) so dictation from the
    /// controller writes into the very same box the keyboard does.
    private var inputField: some View {
        TextField(placeholder, text: $appState.draftText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...6)
            .focused($isFocused)
            .onSubmit(send)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardFillRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.55) : Theme.cardStroke,
                                  lineWidth: 1)
            )
            .disabled(!canCompose)
            .opacity(canCompose ? 1 : 0.6)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(canSend ? Color.white : Theme.textTertiary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(canSend
                                  ? AnyShapeStyle(Theme.accentGradient)
                                  : AnyShapeStyle(Theme.cardFillRaised))
                )
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: canSend ? 0 : 1))
                .shadow(color: canSend ? Theme.accent.opacity(0.45) : .clear, radius: 10, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Send to Claude (⌘↩)")
    }

    private var hasProject: Bool { configStore.config.projectDir != nil }

    /// In remote mode input goes to somebody else's session — no project folder
    /// is needed (or used), so the composer must not be held hostage to one.
    private var isRemote: Bool { configStore.config.controlMode == "remote" }

    private var canCompose: Bool { hasProject || isRemote }

    private var canSend: Bool {
        canCompose && !appState.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        if isRemote { return "Message the remote Claude session…" }
        return hasProject ? "Message Claude…" : "Choose a project folder to start"
    }

    /// Typed text and dictated text leave through the same door: `sendDraft()`
    /// (which is also what the `.sendDraft` controller action calls).
    private func send() {
        guard canCompose else { return }
        appState.sendDraft()
    }
}

// MARK: - Helpers

/// Friendly name of whichever button is currently mapped to push-to-talk —
/// falling back to a dictate-to-draft mapping so a user who only mapped
/// `.pushToTalkDraft` still gets a hint instead of none at all.
private func pushToTalkButtonName(in mapping: [ControllerButton: ControllerAction]) -> String? {
    for button in ControllerButton.allCases where mapping[button] == .pushToTalk {
        return button.displayName
    }
    for button in ControllerButton.allCases where mapping[button] == .pushToTalkDraft {
        return button.displayName
    }
    return nil
}
