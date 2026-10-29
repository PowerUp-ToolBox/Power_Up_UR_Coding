import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/mapping/` case tables (spec #97, slice 2.2)
/// against the Swift app: the action wire shape, action decoding, the
/// intent rule and the hold rule. The Rust core plays the same files
/// (`rust/powerup-core/tests/mapping.rs`), so the two can only agree.
final class MappingFixtureTests: XCTestCase {

    private static let area = "mapping"

    private struct IntentInput: Decodable {
        let action: FixtureJSON
        let phase: String
    }

    // MARK: action-shape.json

    func testActionShapeTable() throws {
        let fileName = "action-shape.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: FixtureJSON.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for fixtureCase in file.cases {
            let action = try Action(fixture: fixtureCase.input)
            let actual = String(decoding: try encoder.encode(action), as: UTF8.self)
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
                                               input: FixtureJSON.self, expected: FixtureJSON.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let config: FixtureJSON = .object(["deviceMappings": .object(["p": .object(["c": fixtureCase.input])])])
            let decoded = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
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
                                               input: IntentInput.self, expected: FixtureJSON.self)
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
                                               input: IntentInput.self, expected: FixtureJSON.self)
        let covered = try file.cases.map { "\(try Action(fixture: $0.input.action).fixtureName) \($0.input.phase)" }
        let every = Action.fixtureCases.flatMap { ["\($0.fixtureName) began", "\($0.fixtureName) ended"] }
        XCTAssertEqual(Set(covered), Set(every))
        XCTAssertEqual(covered.count, every.count, "intent-for-action.json: a duplicated row")
    }

    // MARK: is-hold.json

    func testIsHoldTable() throws {
        let fileName = "is-hold.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: FixtureJSON.self, expected: Bool.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try Action(fixture: fixtureCase.input).isHoldAction
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// The shape and hold tables each hold every case once, so a new action
    /// cannot ship without its wire shape and hold answer pinned.
    func testShapeAndHoldTablesCoverEveryAction() throws {
        let every = Set(Action.fixtureCases.map(\.fixtureName))
        XCTAssertEqual(every.count, 19, "Action.fixtureCases must list every case once")
        let hold = try TextSafetyFixtures.load("is-hold.json", area: Self.area,
                                               input: FixtureJSON.self, expected: Bool.self)
        XCTAssertEqual(try hold.cases.map { try Action(fixture: $0.input).fixtureName }.sorted(),
                       every.sorted())
        let shape = try TextSafetyFixtures.load("action-shape.json", area: Self.area,
                                                input: FixtureJSON.self, expected: String.self)
        XCTAssertEqual(Set(try shape.cases.map { try Action(fixture: $0.input).fixtureName }), every)
    }
}
