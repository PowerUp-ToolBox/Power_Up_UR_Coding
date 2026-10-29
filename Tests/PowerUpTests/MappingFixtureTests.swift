import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/mapping/` case tables (spec #97, slice 2.2)
/// against the Swift app: the action wire shape, action decoding, the
/// intent rule, the hold rule, the default mappings, action resolution and
/// the config mapping subtree. The Rust core plays the same files
/// (`rust/powerup-core/tests/mapping.rs`), so the two can only agree.
final class MappingFixtureTests: XCTestCase {

    private static let area = "mapping"

    private struct IntentInput: Decodable {
        let action: JSONValue
        let phase: String
    }

    // MARK: action-shape.json

    func testActionShapeTable() throws {
        let fileName = "action-shape.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let action = try Action(fixture: fixtureCase.input)
            // The core writes actions into config.json since slice 2.5, so
            // its bytes, through the bridge, are the ones pinned.
            let actual = CoreBridge.wireJSON(of: action) ?? "the core failed"
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: action-decode.json

    /// Through the production path: the action sits under a control in
    /// `deviceMappings`, and AppConfig's decoder keeps or drops the binding.
    func testActionDecodeTable() throws {
        let fileName = "action-decode.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let config: JSONValue = .object(["deviceMappings": .object(["p": .object(["c": fixtureCase.input])])])
            let decoded = try AppConfig.decoded(from: try JSONEncoder().encode(config))
            let actual = decoded.deviceMappings["p"]?["c"]?.fixtureDescriptor ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: intent-for-action.json

    func testIntentForActionTable() throws {
        let fileName = "intent-for-action.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: IntentInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let action = try Action(fixture: fixtureCase.input.action)
            let phase = try ControlPhase(fixture: fixtureCase.input.phase)
            let actual = IntentMapper.intent(for: action, phase: phase)?.fixtureDescriptor ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// Every action meets both phases, so the table is the whole rule.
    func testIntentForActionTableCoversEveryActionAndPhase() throws {
        let file = try TextSafetyFixtures.load("intent-for-action.json", area: Self.area,
                                               input: IntentInput.self, expected: JSONValue.self)
        let covered = try file.cases.map { "\(try Action(fixture: $0.input.action).fixtureName) \($0.input.phase)" }
        let every = Action.fixtureCases.flatMap { ["\($0.fixtureName) began", "\($0.fixtureName) ended"] }
        XCTAssertEqual(Set(covered), Set(every))
        XCTAssertEqual(covered.count, every.count, "intent-for-action.json: a duplicated row")
    }

    // MARK: is-hold.json

    func testIsHoldTable() throws {
        let fileName = "is-hold.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: Bool.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try Action(fixture: fixtureCase.input).isHoldAction
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: default-mapping.json

    func testDefaultMappingTable() throws {
        let fileName = "default-mapping.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        // The button-keyed view the Settings editor reads must agree.
        let buttonKeyed = Dictionary(uniqueKeysWithValues: AppConfig.defaultMapping().map {
            ($0.key.rawValue, $0.value)
        })
        for fixtureCase in file.cases {
            for actual in [AppConfig.defaultDeviceMappings(), [DeviceProfile.dualSenseID: buttonKeyed]] {
                if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase,
                                                             actual: FixtureMappings.descriptor(actual)) {
                    XCTFail(failure)
                }
            }
        }
    }

    // MARK: resolve-action.json

    private struct ResolveInput: Decodable {
        let deviceMappings: JSONValue
        let profile: String
        let control: String
    }

    func testResolveActionTable() throws {
        let fileName = "resolve-action.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: ResolveInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            var config = AppConfig.defaultConfig()
            config.deviceMappings = try FixtureMappings.deviceMappings(fixtureCase.input.deviceMappings)
            let actual = config.action(onProfile: fixtureCase.input.profile,
                                       control: fixtureCase.input.control).fixtureDescriptor
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: config-load.json

    /// Both halves of loading a config.json: what AppConfig's decoder keeps,
    /// and whether ConfigStore copies the file first. The copy runs against a
    /// temporary directory, never the real Application Support folder.
    func testConfigLoadTable() throws {
        let fileName = "config-load.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let data = try JSONEncoder().encode(fixtureCase.input)
            let config = try AppConfig.decoded(from: data)
            let actual: JSONValue = .object([
                "deviceMappings": FixtureMappings.descriptor(config.deviceMappings),
                "backupBeforeSave": .bool(try Self.backupTaken(loading: data)),
            ])
            // "defaults" in the table is the shipped mappings, spelled out
            // here so the comparison is value for value.
            let expectedMappings = try FixtureMappings.deviceMappings(
                fixtureCase.expected["deviceMappings"] ?? .null)
            let normalized = TextSafetyFixtures.StructuredCase(
                name: fixtureCase.name, input: fixtureCase.input,
                expected: JSONValue.object([
                    "deviceMappings": FixtureMappings.descriptor(expectedMappings),
                    "backupBeforeSave": fixtureCase.expected["backupBeforeSave"] ?? .null,
                ]),
                reason: fixtureCase.reason)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, normalized, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    private static func backupTaken(loading data: Data) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try data.write(to: url)
        ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at: url, data: data)
        let backupURL = dir.appendingPathComponent("config.pre-profiles.json")
        return FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// The shape and hold tables each hold every case once, so a new action
    /// cannot ship without its wire shape and hold answer pinned.
    func testShapeAndHoldTablesCoverEveryAction() throws {
        let every = Set(Action.fixtureCases.map(\.fixtureName))
        XCTAssertEqual(every.count, 19, "Action.fixtureCases must list every case once")
        let hold = try TextSafetyFixtures.load("is-hold.json", area: Self.area,
                                               input: JSONValue.self, expected: Bool.self)
        XCTAssertEqual(try hold.cases.map { try Action(fixture: $0.input).fixtureName }.sorted(),
                       every.sorted())
        let shape = try TextSafetyFixtures.load("action-shape.json", area: Self.area,
                                                input: JSONValue.self, expected: String.self)
        XCTAssertEqual(Set(try shape.cases.map { try Action(fixture: $0.input).fixtureName }), every)
    }
}
