import SwiftUI
import AppKit
import AVFAudio
import Speech

// MARK: - Shared palette (used by SettingsView + MappingView)

enum SettingsPalette {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.085)
    static let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.02, green: 0.025, blue: 0.05)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let card = Color.white.opacity(0.05)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.231, green: 0.510, blue: 0.965) // #3B82F6
    static let danger = Color(red: 0.94, green: 0.27, blue: 0.27)
}

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "waveform") }

            ButtonsSettingsTab()
                .tabItem { Label("Buttons", systemImage: "gamecontroller") }

            FeedbackSettingsTab()
                .tabItem { Label("Feedback", systemImage: "bolt.horizontal.circle") }

            RemoteSettingsTab()
                .tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(SettingsPalette.backgroundGradient)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Reusable section card

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(SettingsPalette.accent)
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsPalette.border, lineWidth: 1)
        )
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var configStore: ConfigStore

    private var claudePathBinding: Binding<String> {
        Binding(
            get: { configStore.config.claudePath ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configStore.config.claudePath = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    /// Draft of the comma-separated model cycle while the user types. The raw
    /// text is only parsed (trim whitespace, drop empties) and committed to
    /// `config.modelCycle` on submit or focus loss — normalizing on every
    /// keystroke would erase a just-typed trailing comma and make it impossible
    /// to type the list at all.
    @State private var modelCycleText = ""
    @FocusState private var modelCycleFocused: Bool

    private func commitModelCycle() {
        let items = modelCycleText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        configStore.config.modelCycle = items
        modelCycleText = items.joined(separator: ", ")
    }

    /// Resolved once, off the main thread — the login-shell probe inside
    /// resolveClaudeBinary is far too slow to run inside `body`.
    @State private var autoDetectedPath = "Detecting…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Project") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(SettingsPalette.accent)
                            Text(configStore.config.projectDir ?? "No folder chosen")
                                .foregroundStyle(configStore.config.projectDir == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") {
                                appState.chooseProjectDirectory()
                            }
                        }

                        if configStore.config.recentProjectDirs.count > 1 {
                            Divider()
                            Text("Recent projects — each keeps its own conversation. Map \"Cycle Project\" to a button to switch hands-free.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(configStore.config.recentProjectDirs, id: \.self) { path in
                                HStack {
                                    Text((path as NSString).lastPathComponent)
                                        .lineLimit(1)
                                        .help(path)
                                    Spacer()
                                    if path == configStore.config.projectDir {
                                        Text("current")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Button("Switch") {
                                            appState.switchProject(to: path)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsSection(title: "Harness") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Harness", selection: $configStore.config.harnessKind) {
                            Text("Claude Code (built-in)").tag("claude")
                            Text("ACP agent").tag("acp")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if configStore.config.harnessKind == "acp" {
                            Picker("Agent", selection: $configStore.config.acpAgent) {
                                ForEach(AppConfig.acpAgentOptions, id: \.self) { agent in
                                    Text(AppConfig.acpAgentDisplayName(agent)).tag(agent)
                                }
                            }
                            .pickerStyle(.menu)

                            if configStore.config.acpAgent == "custom" {
                                TextField("/path/to/agent acp", text: $configStore.config.acpCustomCommand)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Text("ACP (Agent Client Protocol) drives other coding agents with the same controller and voice. Notes: Model and Model Cycle must use the agent's own model ids (e.g. openai/gpt-5.3-chat-latest, or leave Default), the effort setting doesn't apply, and cost isn't reported. Switching takes effect with your next message.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsSection(title: "Model") {
                    Picker("Model", selection: $configStore.config.model) {
                        Text("Default").tag("default")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                        Text("Haiku").tag("haiku")
                        Text("Fable").tag("fable")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SettingsSection(title: "Effort") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Effort", selection: $configStore.config.effort) {
                            Text("Default").tag("default")
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                            Text("Extra High").tag("xhigh")
                            Text("Ultra (dynamic workflows)").tag("max")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if configStore.config.effort == "max" {
                            Text("Ultra runs Claude Code at maximum effort and asks it to orchestrate dynamic multi-agent workflows on substantial tasks (your prompts carry the \"ultracode\" keyword). Built-in Claude Code only — expect deeper, slower, costlier turns.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsSection(title: "Model Cycle") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("sonnet, opus, haiku, fable", text: $modelCycleText)
                            .textFieldStyle(.roundedBorder)
                            .focused($modelCycleFocused)
                            .onSubmit { commitModelCycle() }
                        Text("Aliases the Cycle Model button steps through")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Permission Mode") {
                    VStack(spacing: 8) {
                        ForEach(PermissionModeOption.all, id: \.id) { option in
                            PermissionModeRow(
                                option: option,
                                isSelected: configStore.config.permissionMode == option.id
                            ) {
                                configStore.config.permissionMode = option.id
                            }
                        }
                    }
                }

                SettingsSection(title: "Claude Binary") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Override path (optional)", text: claudePathBinding)
                            .textFieldStyle(.roundedBorder)
                        Text("Auto-detected: \(autoDetectedPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Session") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(configStore.config.lastSessionID ?? "None")
                                .font(.system(.body, design: .monospaced))
                        }
                        Spacer()
                        Button("New Session") {
                            appState.newSession()
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(SettingsPalette.background)
        .onAppear {
            modelCycleText = configStore.config.modelCycle.joined(separator: ", ")
        }
        .onChange(of: modelCycleFocused) { _, focused in
            if !focused { commitModelCycle() }
        }
        .onChange(of: configStore.config.modelCycle) { _, newValue in
            // Reflect changes made elsewhere (reset, hand-edited config) —
            // but never while the user is mid-edit in this very field.
            if !modelCycleFocused {
                modelCycleText = newValue.joined(separator: ", ")
            }
        }
        .task {
            let detected = await Task.detached(priority: .utility) {
                ClaudeService.resolveClaudeBinary(override: nil)
            }.value
            autoDetectedPath = detected ?? "Not found — install claude or set a path below."
        }
    }
}

private struct PermissionModeOption {
    let id: String
    let title: String
    let explanation: String
    let isDangerous: Bool

    static let all: [PermissionModeOption] = [
        PermissionModeOption(
            id: "acceptEdits",
            title: "Accept Edits (Recommended)",
            explanation: "Automatically accepts file edits; still asks before other risky actions.",
            isDangerous: false
        ),
        PermissionModeOption(
            id: "default",
            title: "Default",
            explanation: "Asks for your approval before edits and other risky actions.",
            isDangerous: false
        ),
        PermissionModeOption(
            id: "plan",
            title: "Plan",
            explanation: "Claude plans out changes but won't apply anything until you approve.",
            isDangerous: false
        ),
        PermissionModeOption(
            id: "bypassPermissions",
            title: "Bypass Permissions",
            explanation: "Auto-approves everything, including risky actions. Use with caution.",
            isDangerous: true
        )
    ]
}

private struct PermissionModeRow: View {
    let option: PermissionModeOption
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(option.isDangerous ? SettingsPalette.danger : SettingsPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .fontWeight(.medium)
                        .foregroundStyle(option.isDangerous ? SettingsPalette.danger : .primary)
                    Text(option.explanation)
                        .font(.caption)
                        .foregroundStyle(option.isDangerous ? SettingsPalette.danger.opacity(0.85) : .secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? SettingsPalette.accent.opacity(0.12) : Color.white.opacity(0.02))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice tab

private struct VoiceSettingsTab: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var speech: SpeechService
    @EnvironmentObject var tts: TTSService
    @EnvironmentObject var audioDevices: AudioDeviceStore

    private var authLabel: String {
        switch speech.authState {
        case .unknown: return "Not Requested"
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        }
    }

    private var authColor: Color {
        switch speech.authState {
        case .unknown: return .secondary
        case .authorized: return .green
        case .denied: return SettingsPalette.danger
        }
    }

    /// Every locale the speech recognizer supports, named in the user's UI
    /// language ("English (United States) — en-US"), sorted by name. If the
    /// saved value isn't supported (hand-edited config, removed locale), it's
    /// kept as an extra row so the picker never shows a lie — and gets a
    /// warning label so the fix is obvious.
    private var supportedSpeechLocales: [(identifier: String, name: String)] {
        var options = SFSpeechRecognizer.supportedLocales().map { locale -> (identifier: String, name: String) in
            let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? identifier
            return (identifier, "\(name) — \(identifier)")
        }
        options.sort { $0.name < $1.name }

        let current = configStore.config.localeID
        if !options.contains(where: { $0.identifier == current }) {
            options.insert((current, "\(current) — not supported on this Mac"), at: 0)
        }
        return options
    }

    /// Test phrase + routing language matched to the currently selected voice.
    /// A fixed English phrase would always detect "en" and resolution rule 2
    /// would route past a non-English selection to the best en voice — the
    /// user would press Test Voice and never hear the voice they just picked.
    /// Speaking a phrase in the voice's own language (with the language pinned)
    /// makes every selection auditionable.
    private var testVoiceSample: (phrase: String, language: String?) {
        let english = "This is how PowerUp will sound when Claude replies."
        guard let id = configStore.config.ttsVoiceID,
              let voice = AVSpeechSynthesisVoice(identifier: id) else {
            return (english, nil)
        }
        let lang = voice.language.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        switch lang {
        case "zh": return ("你好，这是 PowerUp 朗读 Claude 回复时的声音。", "zh")
        case "ja": return ("こんにちは。これは PowerUp が Claude の返信を読み上げる声です。", "ja")
        case "ko": return ("안녕하세요. PowerUp이 Claude의 답변을 읽어 줄 때 이런 목소리로 들립니다.", "ko")
        default: return (english, lang)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Audio Devices") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Microphone", selection: $configStore.config.audioInputUID) {
                            Text("System Default").tag(String?.none)
                            ForEach(audioDevices.inputDevices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                            // Keep an unplugged pick selectable/visible instead
                            // of silently snapping the picker back to default.
                            if let uid = configStore.config.audioInputUID,
                               audioDevices.inputDevice(forUID: uid) == nil {
                                Text("(Disconnected device)").tag(String?.some(uid))
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Speech Output", selection: $configStore.config.audioOutputUID) {
                            Text("System Default").tag(String?.none)
                            ForEach(audioDevices.outputDevices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                            if let uid = configStore.config.audioOutputUID,
                               audioDevices.outputDevice(forUID: uid) == nil {
                                Text("(Disconnected device)").tag(String?.some(uid))
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Dictation listens on the chosen microphone and replies speak through the chosen output. If a device unplugs mid-session, PowerUp falls back to the system default and switches back when it returns.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsSection(title: "Text to Speech") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Speak Claude's replies", isOn: $configStore.config.ttsEnabled)

                        Picker("Voice", selection: $configStore.config.ttsVoiceID) {
                            Text("Automatic (Best Available)").tag(String?.none)
                            ForEach(tts.availableVoices) { voice in
                                // voice.name is already "Name (language) · Quality".
                                Text(voice.name).tag(String?.some(voice.id))
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Your chosen voice speaks replies in its own language. Replies in another language use the best installed voice for that language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle("Summarize long replies (uses a fast model)", isOn: $configStore.config.speakSummaries)
                        Text("When a reply is long, a lightweight model writes a one-to-two-sentence conclusion and PowerUp speaks that instead of the whole reply — the full text stays in the transcript, and Replay Last Reply still reads it in full. Uses your claude login; each summary costs a fraction of a cent. If the summary can't be made, the full reply is spoken as usual.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speaking Rate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $configStore.config.ttsRate, in: 0.3...0.7)
                        }

                        Stepper(
                            "Max spoken characters: \(configStore.config.maxSpokenChars) (0 = no limit)",
                            value: $configStore.config.maxSpokenChars,
                            in: 0...2000,
                            step: 50
                        )

                        Button("Test Voice") {
                            let sample = testVoiceSample
                            tts.speak(
                                sample.phrase,
                                voiceID: configStore.config.ttsVoiceID,
                                rate: configStore.config.ttsRate,
                                language: sample.language
                            )
                        }
                    }
                }

                SettingsSection(title: "Voice Quality") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("For a much nicer voice, download an Enhanced or Premium voice (System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…), then pick it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Voice Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }

                SettingsSection(title: "Speech Recognition") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Language you speak", selection: $configStore.config.localeID) {
                            ForEach(supportedSpeechLocales, id: \.identifier) { option in
                                Text(option.name).tag(option.identifier)
                            }
                        }
                        .frame(maxWidth: 380, alignment: .leading)

                        Text("Push-to-talk transcribes what you say in THIS language. If your dictation comes out as gibberish or the wrong script, this doesn't match the language you're speaking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle("On-device recognition", isOn: $configStore.config.onDeviceRecognition)
                        Text("Keeps audio on your Mac and works offline, but is noticeably less accurate. Leave off for the best recognition.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Authorization:")
                                .foregroundStyle(.secondary)
                            Text(authLabel)
                                .fontWeight(.medium)
                                .foregroundStyle(authColor)
                            Spacer()
                            Button("Request Permissions") {
                                Task { _ = await speech.requestPermissionsIfNeeded() }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(SettingsPalette.background)
        .onChange(of: configStore.config.localeID) { _, newValue in
            speech.configure(localeID: newValue, onDevice: configStore.config.onDeviceRecognition)
        }
        .onChange(of: configStore.config.onDeviceRecognition) { _, newValue in
            speech.configure(localeID: configStore.config.localeID, onDevice: newValue)
        }
    }
}

// MARK: - Buttons tab

private struct ButtonsSettingsTab: View {
    var body: some View {
        MappingView()
            .background(SettingsPalette.background)
    }
}

// MARK: - Feedback tab

private struct FeedbackSettingsTab: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Controller Feedback") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Haptic feedback", isOn: $configStore.config.hapticsEnabled)
                        Toggle("Light bar", isOn: $configStore.config.lightEnabled)
                    }
                }
            }
            .padding(20)
        }
        .background(SettingsPalette.background)
    }
}

// MARK: - Remote tab

/// Small filled/outline dot used throughout this tab for availability at a
/// glance (cmux reachable, Accessibility granted, listener running).
private struct AvailabilityDot: View {
    let isGood: Bool

    var body: some View {
        Circle()
            .fill(isGood ? Color.green : SettingsPalette.danger)
            .frame(width: 8, height: 8)
    }
}

/// One row of the "Specific app" picker: a running, user-facing app with a
/// usable (non-empty) bundle identifier.
private struct RunningAppChoice: Identifiable, Hashable {
    let id: String     // bundle identifier — non-empty by construction
    let name: String
}

private struct RemoteSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var remote: RemoteControlService
    @EnvironmentObject var listener: RemoteListener

    @State private var hookState: HookInstaller.InstallState = .notInstalled
    @State private var hookActionError: String?

    /// Cached rather than recomputed in `body` — `NSWorkspace` enumeration on
    /// every render is wasteful, and the list only changes when apps launch/quit.
    @State private var runningApps: [RunningAppChoice] = []

    /// Draft of the port while the user types; committed (and validated) only
    /// on submit or focus loss. Writing per keystroke would rebind the listener
    /// to every partial number ("4", "48", "480"…) on the way to the real one.
    @State private var portText = ""
    @FocusState private var portFocused: Bool

    // MARK: Bindings

    private var workspaceBinding: Binding<String?> {
        Binding(
            get: { configStore.config.remoteCmuxWorkspace },
            set: { configStore.config.remoteCmuxWorkspace = $0 }
        )
    }

    private var surfaceBinding: Binding<String> {
        Binding(
            get: { configStore.config.remoteCmuxSurface ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configStore.config.remoteCmuxSurface = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var cmuxPasswordBinding: Binding<String> {
        Binding(
            get: { configStore.config.remoteCmuxPassword ?? "" },
            set: { newValue in
                configStore.config.remoteCmuxPassword = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var appBundleBinding: Binding<String?> {
        Binding(
            get: { configStore.config.remoteAppBundleID },
            set: { configStore.config.remoteAppBundleID = $0 }
        )
    }

    /// Only regular, user-facing apps with a real bundle identifier — an app
    /// without one can't be targeted (it would silently fall back to
    /// "frontmost"), and duplicate/nil ForEach ids break SwiftUI identity.
    private static func currentRunningApps() -> [RunningAppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppChoice? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
                return RunningAppChoice(id: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshHookState() {
        hookState = HookInstaller.installState(
            port: Int(AppState.sanitizedPort(configStore.config.listenerPort)),
            token: configStore.config.listenerToken
        )
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(trimmed), (1024...65535).contains(port) {
            configStore.config.listenerPort = port
        }
        // Snap the field back to whatever is actually stored (also undoes an
        // out-of-range or empty entry).
        portText = String(configStore.config.listenerPort)
        refreshHookState()
    }

    /// Human-readable label for a `remoteTargetKind` raw value. Kept local to
    /// this view rather than in Models.swift so this file's UI wording doesn't
    /// depend on another module's exact symbol shape — it only needs the raw
    /// strings `AppConfig.remoteTargetKinds` already publishes.
    private static func targetKindDisplayName(_ kind: String) -> String {
        switch kind {
        case "cmux": return "cmux (no permission needed)"
        case "app": return "Terminal / specific app"
        case "frontmost": return "Frontmost app"
        default: return kind.capitalized
        }
    }

    /// Common terminal apps offered as one-click presets when the "app"
    /// target kind is selected — sourced from `AppConfig.knownTerminalApps`,
    /// with cmux itself excluded: targeting cmux through keystroke injection
    /// would work, but the dedicated **cmux** target kind reaches it over a
    /// socket with no permission needed, so the UI steers people there instead.
    private static var terminalPresets: [RunningAppChoice] {
        AppConfig.knownTerminalApps
            .filter { $0.name.localizedCaseInsensitiveCompare("cmux") != .orderedSame }
            .map { RunningAppChoice(id: $0.bundleID, name: $0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("cmux is the easiest target — it needs no macOS permission. Terminal/other apps use keystroke injection and require Accessibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                modeSection
                if configStore.config.controlMode == "remote" {
                    targetSection
                    accessibilitySection
                }
                readBackSection
            }
            .padding(20)
        }
        .background(SettingsPalette.background)
        .task {
            remote.refreshStatus()
            portText = String(configStore.config.listenerPort)
            runningApps = Self.currentRunningApps()
            refreshHookState()
        }
        .onChange(of: portFocused) { _, focused in
            if !focused { commitPort() }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        SettingsSection(title: "Control Mode") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Control Mode", selection: $configStore.config.controlMode) {
                    Text("Built-in").tag("builtin")
                    Text("Remote").tag("remote")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built-in — PowerUp runs and manages its own Claude Code session inside the project folder you choose.")
                        .font(.caption)
                        .foregroundStyle(configStore.config.controlMode == "builtin" ? .primary : .secondary)
                    Text("Remote — PowerUp sends your voice and button presses into an existing terminal or cmux session instead, and reads replies back via Claude Code hooks.")
                        .font(.caption)
                        .foregroundStyle(configStore.config.controlMode == "remote" ? .primary : .secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Target

    private var targetSection: some View {
        SettingsSection(title: "Target") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Target Kind", selection: $configStore.config.remoteTargetKind) {
                    ForEach(AppConfig.remoteTargetKinds, id: \.self) { kind in
                        Text(Self.targetKindDisplayName(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch configStore.config.remoteTargetKind {
                case "cmux": cmuxTarget
                case "app": appTarget
                default: frontmostTarget
                }

                Toggle("Press Enter after sending text", isOn: $configStore.config.remoteAutoSubmit)
            }
        }
    }

    private var cmuxTarget: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AvailabilityDot(isGood: remote.cmuxAvailable)
                Text(remote.cmuxAvailable ? "cmux is available" : "cmux can't be reached")
                    .font(.caption)
                    .foregroundStyle(remote.cmuxAvailable ? .secondary : SettingsPalette.danger)
                Spacer()
                Button("Test connection") { remote.refreshStatus() }
            }

            if !remote.cmuxAvailable, let detail = remote.cmuxStatusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Workspace", selection: workspaceBinding) {
                Text("Auto (selected workspace)").tag(String?.none)
                ForEach(remote.cmuxWorkspaces, id: \.ref) { workspace in
                    // displayName prefixes the short ref and falls back to it
                    // when the title is empty — two same-titled workspaces stay
                    // tellable apart, and an untitled one isn't a blank row.
                    Text(workspace.displayName).tag(String?.some(workspace.ref))
                }
            }
            .pickerStyle(.menu)

            TextField("Surface (optional)", text: surfaceBinding)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                SecureField("cmux socket password (if using Password mode)", text: cmuxPasswordBinding)
                    .textFieldStyle(.roundedBorder)
                Text("cmux blocks outside apps by default. In cmux: Settings → Automation → set Socket control mode to Password (or Automation), then quit & reopen cmux. For Password mode, enter the same password here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appTarget: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !Self.terminalPresets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick pick")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(Self.terminalPresets) { preset in
                            Button(preset.name) {
                                configStore.config.remoteAppBundleID = preset.id
                            }
                            .buttonStyle(.bordered)
                            .tint(configStore.config.remoteAppBundleID == preset.id ? SettingsPalette.accent : nil)
                        }
                    }
                }
            }

            HStack {
                Picker("App", selection: appBundleBinding) {
                    Text("Choose an app…").tag(String?.none)
                    ForEach(runningApps) { app in
                        Text(app.name).tag(String?.some(app.id))
                    }
                }
                .pickerStyle(.menu)

                Button("Refresh") { runningApps = Self.currentRunningApps() }
            }

            Text("Text is typed into this app whenever you press a mapped button or finish dictating; the app is activated first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var frontmostTarget: some View {
        Text("Text is typed into whatever app is frontmost at the moment you press a mapped button or finish dictating.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Accessibility

    private var accessibilitySection: some View {
        // Accessibility is ONLY needed for keystroke injection into a Frontmost/
        // Specific app. cmux drives the session over its own socket, so for a
        // cmux target this permission is irrelevant — don't alarm the user.
        let needsAX = configStore.config.remoteTargetKind != "cmux"
        return SettingsSection(title: "Accessibility") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if remote.axTrusted {
                        AvailabilityDot(isGood: true)
                        Text("Access granted").foregroundStyle(.secondary)
                    } else if needsAX {
                        AvailabilityDot(isGood: false)
                        Text("Access needed").foregroundStyle(SettingsPalette.danger)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                        Text("Not required for cmux").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Grant Access") { remote.requestAXTrust() }
                        .disabled(remote.axTrusted)
                }
                Text("Only Frontmost App and Specific App targets need this — cmux targets don't. Note: a grant sticks across rebuilds only when the app is stably signed — run scripts/setup-signing.sh once (details in the README).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if needsAX && !remote.axTrusted {
                    HStack {
                        Text("Or switch to cmux — it needs no permission")
                            .font(.caption)
                            .foregroundStyle(SettingsPalette.accent)
                        Spacer()
                        Button("Switch to cmux") {
                            configStore.config.remoteTargetKind = "cmux"
                        }
                    }
                }
            }
        }
    }

    // MARK: Read-back

    private var hookStatusLabel: String {
        switch hookState {
        case .notInstalled: return "Hooks not installed"
        case .installed: return "Hooks installed"
        case .outOfDate: return "Hooks installed (out of date — reinstall)"
        }
    }

    private var hookStatusColor: Color {
        switch hookState {
        case .installed: return .secondary
        case .notInstalled: return SettingsPalette.danger
        case .outOfDate: return Color.orange
        }
    }

    private var curlTestCommand: String {
        let port = AppState.sanitizedPort(configStore.config.listenerPort)
        let token = configStore.config.listenerToken
        return """
        curl -s -X POST -H "X-PowerUp-Token: \(token)" \
        --data '{"hook_event_name":"Stop","last_assistant_message":"hello"}' \
        http://127.0.0.1:\(port)/event
        """
    }

    private var readBackSection: some View {
        SettingsSection(title: "Read-back (Claude Code Hooks)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AvailabilityDot(isGood: listener.isRunning)
                    Text(listener.isRunning ? "Listener running" : "Listener stopped")
                        .foregroundStyle(listener.isRunning ? .secondary : SettingsPalette.danger)
                    Spacer()
                }
                if let error = listener.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.danger)
                }

                HStack {
                    Text("Port")
                    TextField("48738", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($portFocused)
                        .onSubmit { commitPort() }
                    Text("1024–65535")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Token")
                    Text(configStore.config.listenerToken)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 220, alignment: .leading)
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configStore.config.listenerToken, forType: .string)
                    }
                    Button("Copy curl Test") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(curlTestCommand, forType: .string)
                    }
                    .help("Copies a ready-made curl command that posts a fake Stop event to the listener — a 204/no output means it's listening and the token matches.")
                }

                HStack {
                    Text(hookStatusLabel)
                        .foregroundStyle(hookStatusColor)
                    Spacer()
                    Button("Install Claude Code Hooks") { installHooks() }
                    Button("Uninstall Hooks") { uninstallHooks() }
                        .disabled(hookState == .notInstalled)
                }

                if let hookActionError {
                    Text(hookActionError)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Installing adds a small script to ~/.claude/settings.json (a backup is made first) so ANY terminal or cmux Claude Code session — not just this app's own — can speak its replies back through PowerUp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Routed through AppState (not straight to HookInstaller) so the sanitized
    /// port, the empty-token guard, the listener restart, and the transcript
    /// confirmation all actually happen.
    private func installHooks() {
        hookActionError = appState.installRemoteHooks()
        refreshHookState()
    }

    private func uninstallHooks() {
        hookActionError = appState.uninstallRemoteHooks()
        refreshHookState()
    }
}
