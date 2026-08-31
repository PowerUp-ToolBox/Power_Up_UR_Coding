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
