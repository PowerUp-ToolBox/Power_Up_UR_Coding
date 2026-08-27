import SwiftUI

// MARK: - MappingView

struct MappingView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(ControllerButton.allCases) { button in
                    MappingRow(button: button, configStore: configStore)
                        .listRowBackground(SettingsPalette.card)
                        .listRowSeparatorTint(SettingsPalette.border)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SettingsPalette.background)

            Divider()

            HStack {
                Text("Edits apply immediately and save automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    configStore.resetMappingToDefault()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
            .padding(12)
            .background(SettingsPalette.background)
        }
        .background(SettingsPalette.background)
    }
}

// MARK: - Row

private struct MappingRow: View {
    let button: ControllerButton
    @ObservedObject var configStore: ConfigStore

    private var actionBinding: Binding<ControllerAction> {
        Binding(
            get: { configStore.config.mapping[button] ?? .none },
            set: { configStore.config.mapping[button] = $0 }
        )
    }

    private var kindBinding: Binding<ActionKind> {
        Binding(
            get: { ActionKind(action: actionBinding.wrappedValue) },
            set: { newKind in
                actionBinding.wrappedValue = newKind.makeAction(preserving: actionBinding.wrappedValue)
            }
        )
    }

    private var promptTextBinding: Binding<String> {
        Binding(
            get: {
                if case .sendPrompt(let text) = actionBinding.wrappedValue { return text }
                return ""
            },
            set: { actionBinding.wrappedValue = .sendPrompt($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: Theme.symbol(for: button))
                    .font(.title3)
                    .foregroundStyle(SettingsPalette.accent)
                    .frame(width: 28)

                Text(button.displayName)
                    .fontWeight(.medium)

                Spacer()

                Picker("", selection: kindBinding) {
                    Section("Conversation") {
                        actionRow(.approve)
                        actionRow(.reject)
                        actionRow(.sendPrompt)
                        actionRow(.sendDraft)
                    }
                    Section("Voice") {
                        actionRow(.pushToTalk)
                        actionRow(.pushToTalkDraft)
                        actionRow(.stopSpeaking)
                        actionRow(.replayLastReply)
                        actionRow(.toggleTTS)
                    }
                    Section("Session") {
                        actionRow(.interrupt)
                        actionRow(.newSession)
                        actionRow(.cycleModel)
                        actionRow(.cycleEffort)
                        actionRow(.cyclePermissionMode)
                        actionRow(.cycleProject)
                        actionRow(.toggleControlMode)
                    }
                    Section("App") {
                        actionRow(.showWindow)
                        actionRow(.none)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            if kindBinding.wrappedValue == .sendPrompt {
                TextField("Prompt text", text: promptTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    /// One tagged menu row, built from the kind so the label/tag can never drift.
    private func actionRow(_ kind: ActionKind) -> some View {
        Text(kind.displayName).tag(kind)
    }
}

// MARK: - ActionKind

/// A `Picker`-friendly projection of `ControllerAction` that strips associated
/// values so it can drive a simple selection control; `sendPrompt`'s text is
/// preserved separately via `promptTextBinding` and reattached in `makeAction`.
private enum ActionKind: String, CaseIterable, Identifiable, Hashable {
    case none
    case pushToTalk
    case approve
    case reject
    case interrupt
    case stopSpeaking
    case replayLastReply
    case toggleTTS
    case newSession
    case showWindow
    case cycleModel
    case cycleEffort
    case cyclePermissionMode
    case cycleProject
    case toggleControlMode
    case sendPrompt
    case pushToTalkDraft
    case sendDraft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .pushToTalk: return "Push to Talk"
        case .approve: return "Approve (Yes)"
        case .reject: return "Reject (No)"
        case .interrupt: return "Interrupt"
        case .stopSpeaking: return "Stop Speaking"
        case .replayLastReply: return "Replay Last Reply"
        case .toggleTTS: return "Toggle Speech"
        case .newSession: return "New Session"
        case .showWindow: return "Show Window"
        case .cycleModel: return "Cycle Model"
        case .cycleEffort: return "Cycle Effort"
        case .cyclePermissionMode: return "Cycle Permission Mode"
        case .cycleProject: return "Cycle Project"
        case .toggleControlMode: return "Toggle Built-in / Remote"
        case .sendPrompt: return "Send Prompt…"
        case .pushToTalkDraft: return "Dictate to Prompt Box"
        case .sendDraft: return "Send Prompt Box"
        }
    }

    init(action: ControllerAction) {
        switch action {
        case .none: self = .none
        case .pushToTalk: self = .pushToTalk
        case .sendPrompt: self = .sendPrompt
        case .approve: self = .approve
        case .reject: self = .reject
        case .interrupt: self = .interrupt
        case .stopSpeaking: self = .stopSpeaking
        case .replayLastReply: self = .replayLastReply
        case .toggleTTS: self = .toggleTTS
        case .newSession: self = .newSession
        case .showWindow: self = .showWindow
        case .cycleModel: self = .cycleModel
        case .cycleEffort: self = .cycleEffort
        case .cyclePermissionMode: self = .cyclePermissionMode
        case .cycleProject: self = .cycleProject
        case .toggleControlMode: self = .toggleControlMode
        case .pushToTalkDraft: self = .pushToTalkDraft
        case .sendDraft: self = .sendDraft
        }
    }

    /// Builds the `ControllerAction` for this kind, reusing `current`'s prompt
    /// text if it was already a `.sendPrompt` (so switching away and back
    /// doesn't lose what was typed).
    func makeAction(preserving current: ControllerAction) -> ControllerAction {
        switch self {
        case .none: return .none
        case .pushToTalk: return .pushToTalk
        case .approve: return .approve
        case .reject: return .reject
        case .interrupt: return .interrupt
        case .stopSpeaking: return .stopSpeaking
        case .replayLastReply: return .replayLastReply
        case .toggleTTS: return .toggleTTS
        case .newSession: return .newSession
        case .showWindow: return .showWindow
        case .cycleModel: return .cycleModel
        case .cycleEffort: return .cycleEffort
        case .cyclePermissionMode: return .cyclePermissionMode
        case .cycleProject: return .cycleProject
        case .toggleControlMode: return .toggleControlMode
        case .pushToTalkDraft: return .pushToTalkDraft
        case .sendDraft: return .sendDraft
        case .sendPrompt:
            if case .sendPrompt(let text) = current { return .sendPrompt(text) }
            return .sendPrompt("Continue")
        }
    }
}
