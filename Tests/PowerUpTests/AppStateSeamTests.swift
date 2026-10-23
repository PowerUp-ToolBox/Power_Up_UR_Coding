import XCTest
@testable import PowerUp

/// Proves the AppState test seam (#110): AppState can be constructed with its
/// collaborators injected and none of the production start-up side effects
/// run — no controller start, no audio-device listener, no loopback port
/// bind, no keyboard monitor, no terminate observer, no cmux probe, and no
/// permission prompt — while every callback is still wired, so later suites
/// reach the same handlers production does.
@MainActor
final class AppStateSeamTests: XCTestCase {

    private var env: AppStateTestEnvironment!

    override func setUpWithError() throws {
        env = try AppStateTestEnvironment()
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
    }

    // MARK: Construction without side effects

    func testInitialPublishedStateWithNoSideEffects() {
        let speech = SpeechService()
        let listener = RemoteListener()
        let app = env.makeAppState(speech: speech, listener: listener)

        // No pad is connected and nothing is happening: the resting state.
        XCTAssertEqual(app.status, .noController)
        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(app.isDraftDictation)
        XCTAssertFalse(app.remoteTurnActive)
        XCTAssertNil(app.pendingPermission)
        XCTAssertNil(app.lastAssistantReply)
        XCTAssertEqual(app.liveAssistantText, "")
        XCTAssertEqual(app.draftText, "")
        XCTAssertTrue(app.transcript.isEmpty)
        XCTAssertFalse(app.isRemoteMode)

        // No permission prompt: speech authorization was never asked for.
        XCTAssertEqual(speech.authState, .unknown)
        XCTAssertFalse(speech.isListening)

        // No port bind: the listener was never started.
        XCTAssertFalse(listener.isRunning)
        XCTAssertNil(listener.activePort)
    }

    func testStartUpServicesAreNotStarted() {
        let controller = ControllerService()
        let audioDevices = AudioDeviceStore()
        let app = env.makeAppState(controller: controller, audioDevices: audioDevices)

        XCTAssertFalse(controller.didStart, "the controller service must not register for pads")
        XCTAssertFalse(controller.isConnected)
        XCTAssertFalse(audioDevices.didStart, "the audio device store must not install its hardware listener")
        XCTAssertTrue(audioDevices.inputDevices.isEmpty)
        XCTAssertFalse(app.hasKeyboardMonitor, "no NSEvent monitor in a test")
        XCTAssertFalse(app.hasTerminateObserver, "no global willTerminate observer in a test")
    }

    func testRestartListenerDoesNotBindWhenListenerSyncIsSkipped() {
        let listener = RemoteListener()
        let app = env.makeAppState(listener: listener)

        app.restartListener()

        XCTAssertFalse(listener.isRunning)
        XCTAssertNil(listener.activePort)
    }

    // MARK: Wiring still happens

    func testCallbacksAreWiredToTheSameHandlersAsProduction() {
        let controller = ControllerService()
        let claude = ClaudeService()
        let tts = TTSService()
        let listener = RemoteListener()
        _ = env.makeAppState(controller: controller, tts: tts, claude: claude, listener: listener)

        XCTAssertNotNil(controller.onButtonDown)
        XCTAssertNotNil(controller.onButtonUp)
        XCTAssertNotNil(controller.onDisconnect)
        XCTAssertNotNil(controller.onLowBattery)
        XCTAssertNotNil(claude.onHarnessEvent)
        XCTAssertNotNil(tts.onFinished)
        XCTAssertNotNil(listener.onEvent)
        XCTAssertNotNil(listener.onIntent)
        XCTAssertNotNil(listener.welcomeSnapshot)
    }

    func testControllerCallbackReachesAppState() {
        let controller = ControllerService()
        let app = env.makeAppState(controller: controller)

        controller.onLowBattery?(0.15)

        XCTAssertEqual(app.transcript.last?.kind, .system)
        XCTAssertEqual(app.transcript.last?.text, "🔋 Controller battery is low (15%) — plug it in soon.")
    }

    func testWelcomeSnapshotReportsTheInitialStatus() throws {
        let listener = RemoteListener()
        let app = env.makeAppState(listener: listener)

        // The listener holds AppState weakly, so keep it alive for the call.
        let snapshot = try withExtendedLifetime(app) { try XCTUnwrap(listener.welcomeSnapshot?()) }
        XCTAssertEqual(snapshot.first?["type"] as? String, "status")
        XCTAssertEqual(snapshot.first?["status"] as? String, "noController")
    }

    // MARK: Hermetic storage

    func testConfigStoreMintsItsTokenIntoTheInjectedFileOnly() throws {
        let store = env.makeConfigStore()
        _ = env.makeAppState(configStore: store)

        XCTAssertFalse(store.config.listenerToken.isEmpty)
        let data = try Data(contentsOf: env.configURL)
        let onDisk = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(onDisk.listenerToken, store.config.listenerToken)
    }

    func testInitAdoptsAStoredRemoteModeSilently() throws {
        env.tearDown()
        var config = AppConfig.defaultConfig()
        config.controlMode = "remote"
        config.listenerToken = "test-token"
        env = try AppStateTestEnvironment(config: config)

        let app = env.makeAppState()

        XCTAssertTrue(app.isRemoteMode)
        // Adopting the stored mode runs none of the mode-switch side effects.
        XCTAssertTrue(app.transcript.isEmpty)
    }

    func testInitRestoresTheProjectTranscriptFromTheSandbox() throws {
        env.tearDown()
        let project = "/tmp/powerup-seam-project"
        var config = AppConfig.defaultConfig()
        config.projectDir = project
        config.listenerToken = "test-token"
        env = try AppStateTestEnvironment(config: config)

        let seed = TranscriptStore()
        seed.setProject(project)
        seed.append(TranscriptEntry(kind: .user, text: "hello from before"))

        let app = env.makeAppState()

        XCTAssertEqual(app.transcript.map(\.text),
                       ["hello from before", "Earlier conversation restored — New Session starts clean."])
    }
}
