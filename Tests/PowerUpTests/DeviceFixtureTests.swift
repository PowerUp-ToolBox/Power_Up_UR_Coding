import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/device/` case tables (spec #97, slice 2.2)
/// against the Swift app: the control-kind rule, profile decoding and the
/// built-in DualSense profile. The Rust core plays the same files
/// (`rust/powerup-core/tests/device.rs`).
final class DeviceFixtureTests: XCTestCase {

    private static let area = "device"

    // MARK: control-kind.json

    /// Through a whole control, as a profile file holds it. The kind written
    /// back is checked too: the legacy `hold` must never reappear.
    func testControlKindTable() throws {
        let fileName = "control-kind.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: String.self, expected: FixtureJSON.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let control: FixtureJSON = .object([
                "id": .string("c"), "kind": .string(fixtureCase.input),
                "displayName": .string("C"), "symbolName": .string("circle"),
            ])
            let decoded = try? JSONDecoder().decode(ControlDescriptor.self,
                                                    from: JSONEncoder().encode(control))
            let actual: FixtureJSON = decoded.map { .string($0.kind.rawValue) } ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
            if let decoded {
                XCTAssertEqual(try FixtureJSON(encoding: decoded)["kind"], actual,
                               "\(fileName) case \(fixtureCase.name): the kind written back")
            }
        }
    }

    // MARK: profile-decode.json

    func testProfileDecodeTable() throws {
        let fileName = "profile-decode.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: FixtureJSON.self, expected: FixtureJSON.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let profile = try? JSONDecoder().decode(DeviceProfile.self,
                                                    from: JSONEncoder().encode(fixtureCase.input))
            let actual = try profile.map { try FixtureJSON(encoding: $0) } ?? .null
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: dualsense-profile.json

    func testDualSenseProfileTable() throws {
        let fileName = "dualsense-profile.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: FixtureJSON.self, expected: FixtureJSON.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        let actual = try FixtureJSON(encoding: DeviceProfile.dualSense)
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
}
