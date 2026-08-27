import XCTest
@testable import PowerUp

/// The config decoder must stay tolerant forever: a config.json written by any
/// older build (or hand-edited into a partial state) must keep loading with
/// sensible defaults instead of being thrown away.
final class AppConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    // MARK: Default mapping (pinned to the v1.3 layout)

    func testDefaultMappingCoversEveryButton() {
        let mapping = AppConfig.defaultMapping()
        for button in ControllerButton.allCases {
            XCTAssertNotNil(mapping[button], "\(button.rawValue) has no default mapping entry")
        }
    }

    func testDefaultMappingCoreControls() {
        let mapping = AppConfig.defaultMapping()
        XCTAssertEqual(mapping[.r2], .pushToTalk)
        XCTAssertEqual(mapping[.l2], .pushToTalkDraft)
        XCTAssertEqual(mapping[.l1], .sendDraft)
        XCTAssertEqual(mapping[.l3], .cycleModel)
        XCTAssertEqual(mapping[.r3], .cycleEffort)
        XCTAssertEqual(mapping[.touchpad], .cyclePermissionMode)
        XCTAssertEqual(mapping[.ps], ControllerAction.none)
        XCTAssertEqual(mapping[.cross], .approve)
        XCTAssertEqual(mapping[.circle], .interrupt)
        XCTAssertEqual(mapping[.square], .sendPrompt("Continue"))
    }

    func testHoldActions() {
        XCTAssertTrue(ControllerAction.pushToTalk.isHoldAction)
        XCTAssertTrue(ControllerAction.pushToTalkDraft.isHoldAction)
        XCTAssertFalse(ControllerAction.sendDraft.isHoldAction)
        XCTAssertFalse(ControllerAction.approve.isHoldAction)
    }

    func testEffortCycleEndsAtUltra() {
        XCTAssertEqual(AppConfig.effortCycle, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(AppConfig.effortOptions.contains("max"))
        XCTAssertFalse(AppConfig.effortCycle.contains("default"))
        XCTAssertEqual(AppConfig.effortDisplayName("max"), "Ultra")
        XCTAssertEqual(AppConfig.effortDisplayName("xhigh"), "Extra High")
    }

    func testMultiProjectFieldsDecodeTolerantly() throws {
        let decoded = try decode("{}")
        XCTAssertEqual(decoded.recentProjectDirs, [])
        XCTAssertEqual(decoded.sessionIDsByProject, [:])

        let populated = try decode(#"{"recentProjectDirs":["/a","/b"],"sessionIDsByProject":{"/a":"s1"}}"#)
        XCTAssertEqual(populated.recentProjectDirs, ["/a", "/b"])
        XCTAssertEqual(populated.sessionIDsByProject["/a"], "s1")

        let wrongTypes = try decode(#"{"recentProjectDirs":"nope","sessionIDsByProject":[1]}"#)
        XCTAssertEqual(wrongTypes.recentProjectDirs, [])
        XCTAssertEqual(wrongTypes.sessionIDsByProject, [:])
    }

    func testPermissionCycleNeverContainsBypass() {
        XCTAssertFalse(AppConfig.permissionModeCycle.contains("bypassPermissions"),
                       "a stray button press must never escalate to auto-approve-everything")
    }

    // MARK: Round trip

    func testEncodeDecodeRoundTrip() throws {
        var config = AppConfig.defaultConfig()
        config.projectDir = "/tmp/proj"
        config.model = "opus"
        config.listenerToken = "secret"
        config.mapping[.ps] = .sendPrompt("hello there")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testMappingEncodesAsKeyedObject() throws {
        let config = AppConfig.defaultConfig()
        let data = try JSONEncoder().encode(config)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mapping = try XCTUnwrap(root["mapping"] as? [String: Any],
                                    "mapping must encode as {button: action}, not a flat array")
        XCTAssertNotNil(mapping["r2"])
    }

    // MARK: Tolerant decoding

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), AppConfig.defaultConfig())
    }

    func testOldConfigWithoutNewKeysKeepsItsValues() throws {
        let decoded = try decode(#"{"model":"opus","ttsEnabled":false,"maxSpokenChars":600}"#)
        XCTAssertEqual(decoded.model, "opus")
        XCTAssertFalse(decoded.ttsEnabled)
        XCTAssertEqual(decoded.maxSpokenChars, 600)
        // Newer keys fall back to defaults.
        XCTAssertEqual(decoded.effort, "default")
        XCTAssertEqual(decoded.modelCycle, AppConfig.defaultModelCycle)
        XCTAssertEqual(decoded.controlMode, "builtin")
        XCTAssertEqual(decoded.remoteTargetKind, "cmux")
    }

    func testWrongTypesFallBackToDefaults() throws {
        let decoded = try decode(#"{"model":42,"ttsEnabled":"yes","mapping":[1,2,3]}"#)
        XCTAssertEqual(decoded.model, "default")
        XCTAssertTrue(decoded.ttsEnabled)
        XCTAssertEqual(decoded.mapping, AppConfig.defaultMapping())
    }

    func testUnknownFixedVocabularyValuesFallBackToDefaults() throws {
        let decoded = try decode(#"{"controlMode":"telepathy","remoteTargetKind":"pigeon"}"#)
        XCTAssertEqual(decoded.controlMode, "builtin")
        XCTAssertEqual(decoded.remoteTargetKind, "cmux")
    }

    func testOutOfRangeListenerPortFallsBackToDefault() throws {
        XCTAssertEqual(try decode(#"{"listenerPort":0}"#).listenerPort, AppConfig.defaultListenerPort)
        XCTAssertEqual(try decode(#"{"listenerPort":99999}"#).listenerPort, AppConfig.defaultListenerPort)
        XCTAssertEqual(try decode(#"{"listenerPort":8080}"#).listenerPort, 8080)
    }

    func testEmptyOptionalStringsBecomeNil() throws {
        let decoded = try decode(#"{"projectDir":"","claudePath":"","lastSessionID":""}"#)
        XCTAssertNil(decoded.projectDir)
        XCTAssertNil(decoded.claudePath)
        XCTAssertNil(decoded.lastSessionID)
    }

    func testUnknownActionInMappingFallsBackToDefaultMapping() throws {
        // A mapping containing an action this build doesn't know (from a newer
        // build) fails that key's decode; the tolerant layer falls back to the
        // default mapping rather than throwing the whole config away.
        let decoded = try decode(#"{"model":"haiku","mapping":{"r2":{"warpSpeed":{}}}}"#)
        XCTAssertEqual(decoded.model, "haiku")
        XCTAssertEqual(decoded.mapping, AppConfig.defaultMapping())
    }
}
