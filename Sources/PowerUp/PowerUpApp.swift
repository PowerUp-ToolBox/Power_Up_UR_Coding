import SwiftUI

@main
struct PowerUpApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("PowerUp") {
            MainView()
                .frame(minWidth: 980, minHeight: 640)
                .environmentObjects(appState)
                .onAppear {
                    // Resume the previous session (if any) as soon as the UI is up.
                    appState.startSessionIfNeeded()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Claude Session") {
                    appState.newSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            // Voice without a controller: both capture styles are one shortcut
            // away, and each press toggles (start, then stop) — a keyboard has
            // no held trigger to release. Titles never swap Start/Stop (a
            // closed menu could show it stale); only the dictation target
            // varies, because in remote mode the words are typed into the
            // remote session, not the local prompt box. The disable gate must
            // never block the STOP half of a toggle: a capture can be active
            // while canAcceptInput is false (a mode flip mid-recording), and
            // toggleVoiceCapture's own guard already refuses disallowed starts.
            //
            // IMPORTANT: the .keyboardShortcut modifiers here (and ⌘N above)
            // are DISPLAY ONLY — AppState's local NSEvent monitor intercepts
            // and performs these chords before AppKit's key-equivalent routing
            // runs, because on macOS 26 that routing traps in SwiftUI's
            // ButtonAction (MainActor.assumeIsolated crash; see AppState's
            // KeyboardCommand). Clicking the items still uses these actions.
            CommandMenu("Voice") {
                Button(appState.isRemoteMode ? "Dictate to Remote Session"
                                             : "Dictate to Prompt Box") {
                    appState.toggleVoiceCapture(.draft)
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!appState.canAcceptInput && !appState.isPTTActive)

                Button("Talk to Claude (Sends on Stop)") {
                    appState.toggleVoiceCapture(.send)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!appState.canAcceptInput && !appState.isPTTActive)
            }
        }

        Settings {
            SettingsView()
                .environmentObjects(appState)
        }
    }
}

private extension View {
    /// Injects `AppState` plus every service it owns, so any view can observe the
    /// one object it actually cares about instead of the whole app state.
    @MainActor
    func environmentObjects(_ appState: AppState) -> some View {
        self
            .environmentObject(appState)
            .environmentObject(appState.configStore)
            .environmentObject(appState.controller)
            .environmentObject(appState.speech)
            .environmentObject(appState.tts)
            .environmentObject(appState.claude)
            .environmentObject(appState.remote)
            .environmentObject(appState.listener)
            .environmentObject(appState.audioDevices)
    }
}
