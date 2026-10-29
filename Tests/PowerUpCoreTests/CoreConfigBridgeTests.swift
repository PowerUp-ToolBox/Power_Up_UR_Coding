import XCTest
import PowerUpCore

/// The configuration half of the bridge (slice 2.5): a 35-field record with
/// a Float, Int64s and nested maps, an enum case carrying it, and bytes both
/// ways, all through the generated functions.
final class CoreConfigBridgeTests: XCTestCase {

    func testTheDefaultsSaveAndLoadBack() throws {
        let defaults = try defaultConfig()
        XCTAssertEqual(defaults.ttsRate, 0.5)
        XCTAssertEqual(defaults.listenerPort, 48738)
        XCTAssertNil(defaults.controllerDeviceId)
        XCTAssertEqual(defaults.deviceMappings["dualsense"]?["r2"], .pushToTalk)
        let bytes = try encodeConfig(config: defaults)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix("{\n  \"acpAgent\" : \"opencode\",\n"))
        XCTAssertEqual(try loadConfig(bytes: bytes), .loaded(config: defaults, backupBeforeSave: false))
    }

    func testACorruptFileAndALegacyMappingAreTold() throws {
        XCTAssertEqual(try loadConfig(bytes: Data("[]".utf8)), .corrupt)
        guard case .loaded(let config, let backup) = try loadConfig(
            bytes: Data(#"{"mapping":{"r2":{"approve":{}}},"lastSessionID":"s"}"#.utf8)) else {
            return XCTFail("a legacy config must load")
        }
        XCTAssertTrue(backup)
        XCTAssertEqual(config.deviceMappings, ["dualsense": ["r2": .approve]])
        XCTAssertEqual(config.lastSessionId, "s")
    }

    func testSeedingAndTheVocabulary() throws {
        let fresh = try defaultConfig()
        let config = CoreAppConfig(
            projectDir: "/p", model: fresh.model, permissionMode: fresh.permissionMode,
            claudePath: nil, lastSessionId: "s1", ttsEnabled: fresh.ttsEnabled,
            ttsRate: fresh.ttsRate, ttsVoiceId: nil, maxSpokenChars: fresh.maxSpokenChars,
            speakSummaries: fresh.speakSummaries, summaryModel: fresh.summaryModel,
            localeId: fresh.localeId, onDeviceRecognition: fresh.onDeviceRecognition,
            audioInputUid: nil, audioOutputUid: nil, controllerDeviceId: nil,
            hapticsEnabled: fresh.hapticsEnabled, lightEnabled: fresh.lightEnabled,
            effort: fresh.effort, modelCycle: fresh.modelCycle, harnessKind: fresh.harnessKind,
            acpAgent: fresh.acpAgent, acpCustomCommand: fresh.acpCustomCommand,
            controlMode: fresh.controlMode, remoteTargetKind: fresh.remoteTargetKind,
            remoteCmuxWorkspace: nil, remoteCmuxSurface: nil, remoteAppBundleId: nil,
            remoteCmuxPassword: nil, remoteAutoSubmit: fresh.remoteAutoSubmit,
            listenerPort: fresh.listenerPort, listenerToken: "t", recentProjectDirs: [],
            sessionIdsByProject: [:], deviceMappings: [:])
        let seeded = try seedProjectBookkeeping(config: config)
        XCTAssertEqual(seeded.recentProjectDirs, ["/p"])
        XCTAssertEqual(seeded.sessionIdsByProject, ["/p": "s1"])
        let vocabulary = try configVocabulary()
        XCTAssertEqual(vocabulary.remoteTargetKinds, ["cmux", "app", "frontmost"])
        XCTAssertEqual(vocabulary.harnessKinds, ["claude", "acp"])
    }
}
