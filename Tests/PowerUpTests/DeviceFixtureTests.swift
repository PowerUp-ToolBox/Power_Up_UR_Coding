import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/device/` case tables (spec #97, slice 2.2)
/// against the Swift app: the control-kind rule, profile decoding, the
/// built-in DualSense profile, the Controller slot rule and the hold rule. The Rust core plays the same files
/// (`rust/powerup-core/tests/device.rs`).
final class DeviceFixtureTests: XCTestCase {

    private static let area = "device"

    // MARK: control-kind.json

    /// Through a whole control, as a profile file holds it. The kind written
    /// back is checked too: the legacy `hold` must never reappear.
    func testControlKindTable() throws {
        let fileName = "control-kind.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: String.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let control: JSONValue = .object([
                "id": .string("c"), "kind": .string(fixtureCase.input),
                "displayName": .string("C"), "symbolName": .string("circle"),
            ])
            let decoded = try? JSONDecoder().decode(ControlDescriptor.self,
                                                    from: JSONEncoder().encode(control))
            let actual: JSONValue = decoded.map { .string($0.kind.rawValue) } ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
            if let decoded {
                XCTAssertEqual(try JSONValue(encoding: decoded)["kind"], actual,
                               "\(fileName) case \(fixtureCase.name): the kind written back")
            }
        }
    }

    // MARK: profile-decode.json

    func testProfileDecodeTable() throws {
        let fileName = "profile-decode.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let profile = try? JSONDecoder().decode(DeviceProfile.self,
                                                    from: JSONEncoder().encode(fixtureCase.input))
            let actual = try profile.map { try JSONValue(encoding: $0) } ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: dualsense-profile.json

    func testDualSenseProfileTable() throws {
        let fileName = "dualsense-profile.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        let actual = try JSONValue(encoding: DeviceProfile.dualSense)
        for fixtureCase in file.cases {
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
            // The table's order is the enum's, so the editor lists the
            // controls the same way on both sides.
            guard case .array(let controls)? = fixtureCase.expected["controls"] else {
                return XCTFail("\(fileName) case \(fixtureCase.name): no controls list")
            }
            XCTAssertEqual(controls.compactMap { $0["id"]?.stringValue },
                           ControllerButton.allCases.map(\.rawValue))
        }
    }

    // MARK: slot-selection.json

    func testSlotSelectionTable() throws {
        let fileName = "slot-selection.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            guard case .array(let listed)? = fixtureCase.input["mostRecentlyConnectedFirst"] else {
                throw FixtureValueError(description: "\(fileName) case \(fixtureCase.name): no controller list")
            }
            let pinnedID: String?
            switch fixtureCase.input["pinnedID"] {
            case .null?: pinnedID = nil
            case .string(let id)?: pinnedID = id
            default:
                throw FixtureValueError(description: "\(fileName) case \(fixtureCase.name): pinnedID must be a string or null")
            }
            let slot = ControllerSlotSelector(
                mostRecentlyConnectedFirst: try listed.map { try ConnectedController(fixture: $0) },
                pinnedID: pinnedID
            )
            let actual = slot.active?.fixtureDescriptor ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: hold-rule.json

    /// One tracker per case, starting idle; the steps play in order, as the
    /// AppState adapter feeds presses, releases and the forced release.
    func testHoldRuleTable() throws {
        let fileName = "hold-rule.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        var seen = Set<String>()
        for fixtureCase in file.cases {
            guard case .array(let steps)? = fixtureCase.input["steps"] else {
                throw FixtureValueError(description: "\(fileName) case \(fixtureCase.name): no steps")
            }
            var tracker = HoldTracker()
            var effects: [JSONValue] = []
            for step in steps {
                let effect: HoldEffect
                if step["releaseAll"] == .bool(true) {
                    effect = tracker.releaseAll()
                } else {
                    guard let action = step["action"], let control = step["control"]?.stringValue,
                          let phase = step["phase"]?.stringValue,
                          case .bool(let toggle)? = step["toggleCaptureActive"] else {
                        throw FixtureValueError(description: "\(fileName) case \(fixtureCase.name): bad step \(step)")
                    }
                    effect = tracker.effect(for: try Action(fixture: action), control: control,
                                            phase: try ControlPhase(fixture: phase),
                                            toggleCaptureActive: toggle)
                }
                effects.append(effect.fixtureDescriptor)
                if let name = effect.fixtureDescriptor["effect"]?.stringValue { seen.insert(name) }
            }
            let actual: JSONValue = .object([
                "effects": .array(effects),
                "owner": tracker.owner.map { .string($0) } ?? .null,
            ])
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
        // The table speaks the whole effect vocabulary, so the Rust side
        // playing it checks every name.
        XCTAssertEqual(seen, ["beginCapture", "endCapture", "cancelCapture", "deliver", "ignore"])
    }
}
