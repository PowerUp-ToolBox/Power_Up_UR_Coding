import XCTest
@testable import PowerUp

/// Pins ADR 0006's device-profile keystone: the built-in DualSense profile,
/// the deviceMappings storage shape, the lossless legacy-config migration
/// (#63), and the (profile, control) resolution path every input routes
/// through (#14).
final class DeviceProfileTests: XCTestCase {

    // MARK: The built-in profile

    func testDualSenseProfileCoversEveryButtonExactlyOnce() {
        let ids = DeviceProfile.dualSense.controls.map(\.id)
        XCTAssertEqual(ids, ControllerButton.allCases.map(\.rawValue))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDualSenseProfileMirrorsEnumMetadata() {
        for control in DeviceProfile.dualSense.controls {
            let button = ControllerButton(rawValue: control.id)
            XCTAssertNotNil(button, "\(control.id) is not a ControllerButton")
            XCTAssertEqual(control.displayName, button?.displayName)
            XCTAssertEqual(control.symbolName, button?.symbolName)
        }
    }

    // MARK: Storage shape

    func testDefaultDeviceMappingsMatchDefaultMapping() {
        let stored = AppConfig.defaultDeviceMappings()[DeviceProfile.dualSenseID]
        XCTAssertNotNil(stored)
        for (button, action) in AppConfig.defaultMapping() {
            XCTAssertEqual(stored?[button.rawValue], action, button.rawValue)
        }
        XCTAssertEqual(stored?.count, AppConfig.defaultMapping().count)
    }

    func testEncodeWritesDeviceMappingsAndNoLegacyKey() throws {
        let data = try JSONEncoder().encode(AppConfig.defaultConfig())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["deviceMappings"], "new shape must be written")
        XCTAssertNil(object["mapping"], "legacy key must not be written")
    }

    func testRoundTripPreservesForeignProfiles() throws {
        var config = AppConfig.defaultConfig()
        config.deviceMappings["streamdeck-test"] = ["key-1": .approve, "key-2": .interrupt]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.deviceMappings["streamdeck-test"]?["key-1"], .approve)
        XCTAssertEqual(decoded.deviceMappings["streamdeck-test"]?["key-2"], .interrupt)
        XCTAssertEqual(decoded.deviceMappings[DeviceProfile.dualSenseID],
                       config.deviceMappings[DeviceProfile.dualSenseID])
    }

    // MARK: Legacy migration (#63)

    /// A config.json fragment exactly as a pre-ADR-0006 build wrote it:
    /// button-name keys, including a parameterized action and an explicit none.
    private let legacyFixture = Data("""
    {
        "model": "opus",
        "mapping": {
            "r2": {"pushToTalk": {}},
            "cross": {"approve": {}},
            "square": {"sendPrompt": {"_0": "Run the tests"}},
            "ps": {"none": {}}
        }
    }
    """.utf8)

    func testLegacyMappingMigratesLosslessly() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: legacyFixture)
        let migrated = try XCTUnwrap(config.deviceMappings[DeviceProfile.dualSenseID])
        XCTAssertEqual(migrated["r2"], .pushToTalk)
        XCTAssertEqual(migrated["cross"], .approve)
        XCTAssertEqual(migrated["square"], .sendPrompt("Run the tests"))
        XCTAssertEqual(migrated["ps"], ControllerAction.none)
        XCTAssertEqual(migrated.count, 4, "migration must not invent entries")
        // The bridge sees the same bindings.
        XCTAssertEqual(config.mapping[.square], .sendPrompt("Run the tests"))
    }

    func testMigratedConfigEncodesInNewShapeOnly() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: legacyFixture)
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["deviceMappings"])
        XCTAssertNil(object["mapping"])
    }

    func testNewShapeWinsWhenBothKeysPresent() throws {
        let both = Data("""
        {
            "deviceMappings": {"dualsense": {"cross": {"interrupt": {}}}},
            "mapping": {"cross": {"approve": {}}}
        }
        """.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: both)
        XCTAssertEqual(config.action(onProfile: DeviceProfile.dualSenseID, control: "cross"),
                       .interrupt)
    }

    func testNeitherKeyFallsBackToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.deviceMappings, AppConfig.defaultDeviceMappings())
    }

    // MARK: Resolution and the bridge

    func testActionResolution() {
        let config = AppConfig.defaultConfig()
        XCTAssertEqual(config.action(onProfile: DeviceProfile.dualSenseID, control: "r2"),
                       .pushToTalk)
        XCTAssertEqual(config.action(onProfile: DeviceProfile.dualSenseID, control: "no-such"),
                       ControllerAction.none)
        XCTAssertEqual(config.action(onProfile: "no-such-profile", control: "r2"),
                       ControllerAction.none)
    }

    func testMappingBridgeWritesThrough() {
        var config = AppConfig.defaultConfig()
        config.mapping[.cross] = .interrupt
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["cross"], .interrupt)
        XCTAssertEqual(config.action(onProfile: DeviceProfile.dualSenseID, control: "cross"),
                       .interrupt)
    }

    func testMappingBridgePreservesForeignControlIDs() {
        var config = AppConfig.defaultConfig()
        config.deviceMappings[DeviceProfile.dualSenseID]?["future-axis"] = .approve
        // A bridge edit rewrites button bindings only…
        config.mapping[.cross] = .interrupt
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["future-axis"], .approve)
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["cross"], .interrupt)
        // …and unmapping a button through the bridge still removes it.
        config.mapping[.cross] = nil
        XCTAssertNil(config.deviceMappings[DeviceProfile.dualSenseID]?["cross"])
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["future-axis"], .approve)
    }

    // MARK: Per-entry tolerance (unknown entries drop alone, never the tree)

    func testUnknownActionDropsOnlyThatBinding() throws {
        let json = Data("""
        {
            "deviceMappings": {
                "dualsense": {"r2": {"pushToTalk": {}}, "cross": {"launchMissiles": {}}},
                "pedal": {"pedal-1": {"approve": {}}}
            }
        }
        """.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["r2"], .pushToTalk)
        XCTAssertNil(config.deviceMappings[DeviceProfile.dualSenseID]?["cross"],
                     "the unknown action drops")
        XCTAssertEqual(config.deviceMappings["pedal"]?["pedal-1"], .approve,
                       "other profiles are untouched")
    }

    func testMalformedProfileDropsOnlyThatProfile() throws {
        let json = Data("""
        {
            "deviceMappings": {
                "dualsense": {"r2": {"pushToTalk": {}}},
                "broken": "not an object"
            }
        }
        """.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.deviceMappings[DeviceProfile.dualSenseID]?["r2"], .pushToTalk)
        XCTAssertNil(config.deviceMappings["broken"])
    }

    // MARK: The one-time pre-rewrite backup (ConfigStore seam)

    private func withTempConfig(_ json: String, _ body: (URL, URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try? Data(json.utf8).write(to: url)
        let backupURL = dir.appendingPathComponent("config.pre-profiles.json")
        try body(url, backupURL)
    }

    func testLegacyConfigIsBackedUpOnceBeforeMigration() throws {
        try withTempConfig(#"{"mapping": {"r2": {"pushToTalk": {}}}}"#) { url, backupURL in
            ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at: url, data: try Data(contentsOf: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
            let original = try Data(contentsOf: url)
            // A second load must not overwrite the kept original.
            try Data(#"{"mapping": {}}"#.utf8).write(to: url)
            ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at: url, data: try Data(contentsOf: url))
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
        }
    }

    func testLossyDeviceMappingsAreBackedUp() throws {
        let json = #"{"deviceMappings": {"dualsense": {"cross": {"fromTheFuture": {}}}}}"#
        try withTempConfig(json) { url, backupURL in
            ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at: url, data: try Data(contentsOf: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path),
                          "a mapping the tolerant decoder would thin out must be kept")
        }
    }

    func testHealthyConfigIsNotBackedUp() throws {
        let data = try JSONEncoder().encode(AppConfig.defaultConfig())
        try withTempConfig(String(decoding: data, as: UTF8.self)) { url, backupURL in
            ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at: url, data: try Data(contentsOf: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        }
    }
}
