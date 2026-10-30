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

    func testTheEnvironmentNeverFallsBackToALiveHarness() {
        let app = env.makeAppState()

        XCTAssertTrue(app.harness is FakeHarnessAdapter,
                      "without a harness: argument a send must reach a fake, never spawn a real claude")
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
        XCTAssertEqual(snapshot.first, .status(.noController))
        guard case .session(let session)? = snapshot.last, snapshot.count == 2 else {
            return XCTFail("the snapshot is the status, then the session: \(snapshot)")
        }
        XCTAssertEqual(session.model, app.configStore.config.model)
        XCTAssertEqual(session.costUSD, 0)
        XCTAssertEqual(session.tokens, 0)
    }

    // MARK: Hermetic storage

    func testConfigStoreMintsItsTokenIntoTheInjectedFileOnly() throws {
        let store = env.makeConfigStore()
        _ = env.makeAppState(configStore: store)

        XCTAssertFalse(store.config.listenerToken.isEmpty)
        let data = try Data(contentsOf: env.configURL)
        let onDisk = try AppConfig.decoded(from: data)
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

    /// A config from before several folders were remembered (HK-164): the
    /// folder joins the recents and the single lastSessionID becomes its
    /// session, and the store is saved with both.
    func testInitSeedsTheProjectBookkeeping() throws {
        env.tearDown()
        var config = AppConfig.defaultConfig()
        config.projectDir = "/tmp/powerup-seed-project"
        config.lastSessionID = "3f2b1a4c-1111-2222-3333-444455556666"
        config.recentProjectDirs = ["/tmp/other"]
        config.listenerToken = "test-token"
        env = try AppStateTestEnvironment(config: config)

        let app = env.makeAppState()

        XCTAssertEqual(app.configStore.config.recentProjectDirs,
                       ["/tmp/powerup-seed-project", "/tmp/other"])
        XCTAssertEqual(app.configStore.config.sessionIDsByProject,
                       ["/tmp/powerup-seed-project": "3f2b1a4c-1111-2222-3333-444455556666"])
        app.configStore.save()
        let onDisk = try AppConfig.decoded(from: Data(contentsOf: env.configURL))
        XCTAssertEqual(onDisk.recentProjectDirs, app.configStore.config.recentProjectDirs)
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

    /// HK-177: the window keeps the newest 800 entries, while the file keeps
    /// every one (the core compacts it past 2000 on the next load).
    func testTheWindowKeepsTheNewest800EntriesAndTheFileKeepsAll() throws {
        env.tearDown()
        let project = "/tmp/powerup-seam-cap-project"
        var config = AppConfig.defaultConfig()
        config.projectDir = project
        config.listenerToken = "test-token"
        env = try AppStateTestEnvironment(config: config)
        let app = env.makeAppState()

        for _ in 0..<805 { app.handle(.toggleTTS) }

        XCTAssertEqual(app.transcript.count, 800)
        // Spoken replies start on, so the notes alternate off, on, …; with
        // the five oldest dropped the window starts at the sixth, an "on".
        XCTAssertEqual(app.transcript.first?.text, "Spoken replies on.")
        XCTAssertEqual(app.transcript.last?.text, "Spoken replies off.")
        let file = try XCTUnwrap(TranscriptStore.fileURL(forProjectDir: project))
        XCTAssertEqual(try Data(contentsOf: file).split(separator: 0x0A).count, 805)
    }

    // MARK: Wiring checks that must agree with the core

    /// AppState still reads two settings itself: the control mode (views and
    /// capture ask `isRemoteMode`) and the harness kind (which adapter an
    /// effect goes to). The session rules read the same settings in the core,
    /// so the two readings must never drift apart.
    func testRuntimeNormalizationAgreesWithTheCore() {
        for raw in ["acp", "claude", "ACP", "", "remote", "builtin", "x"] {
            XCTAssertEqual(AppState.normalizedControlMode(raw) == "remote",
                           CoreBridge.isRemoteMode(controlMode: raw), "control mode \(raw)")
            let core: String
            switch CoreBridge.harnessKind(fromSetting: raw) {
            case .claude: core = "claude"
            case .acp: core = "acp"
            }
            XCTAssertEqual(AppState.normalizedHarnessKind(raw), core, "harness kind \(raw)")
        }
    }
}
