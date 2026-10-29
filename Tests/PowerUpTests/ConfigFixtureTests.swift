import XCTest
@testable import PowerUp

/// Plays `Tests/Fixtures/config/round-trip.json`: config.json bytes loaded the
/// way ConfigStore loads them, then saved again. The saved text is compared
/// byte for byte, so the table pins the real on-disk writer, and the
/// pre-profiles copy runs in a temporary directory, never the real
/// Application Support folder.
final class ConfigFixtureTests: XCTestCase {

    func testConfigRoundTripTable() throws {
        let fileName = "round-trip.json"
        let file = try TextSafetyFixtures.load(fileName, area: "config",
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let data = try FixtureLine.bytes(fixtureCase.input)
            var saved = JSONValue.null
            if let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                let text = try XCTUnwrap(String(data: try ConfigStore.encode(config), encoding: .utf8))
                saved = .array(text.components(separatedBy: "\n").map(JSONValue.string))
            }
            let actual: JSONValue = .object([
                "saved": saved,
                "backupBeforeSave": .bool(try Self.backupTaken(loading: data)),
            ])
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
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
}
