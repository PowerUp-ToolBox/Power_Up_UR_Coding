import XCTest
@testable import PowerUp

/// Pins the pure pieces of the audio-device work (#64/#66): the availability
/// tracker behind the came/went transcript announcements, and the new
/// AppConfig fields' tolerant decode/encode. CoreAudio enumeration and engine
/// routing need hardware and are exercised by the app, not the suite.
final class AudioDeviceTests: XCTestCase {

    // MARK: AudioAvailabilityTracker

    func testUnplugAnnouncesOnce() {
        var tracker = AudioAvailabilityTracker()
        XCTAssertNil(tracker.check(configuredUID: "mic-1", isAvailable: true))
        XCTAssertEqual(tracker.check(configuredUID: "mic-1", isAvailable: false),
                       .becameUnavailable)
        // Repeated checks while still absent stay quiet.
        XCTAssertNil(tracker.check(configuredUID: "mic-1", isAvailable: false))
    }

    func testReturnAnnounces() {
        var tracker = AudioAvailabilityTracker()
        _ = tracker.check(configuredUID: "mic-1", isAvailable: true)
        _ = tracker.check(configuredUID: "mic-1", isAvailable: false)
        XCTAssertEqual(tracker.check(configuredUID: "mic-1", isAvailable: true),
                       .becameAvailable)
        XCTAssertNil(tracker.check(configuredUID: "mic-1", isAvailable: true))
    }

    func testSelectionChangeRebaselinesSilently() {
        var tracker = AudioAvailabilityTracker()
        _ = tracker.check(configuredUID: "mic-1", isAvailable: true)
        // Switching devices is not an unplug — no announcement, even though
        // the new pick starts out absent.
        XCTAssertNil(tracker.check(configuredUID: "mic-2", isAvailable: false))
        // …but the next transition of the new pick announces normally.
        XCTAssertEqual(tracker.check(configuredUID: "mic-2", isAvailable: true),
                       .becameAvailable)
    }

    func testSystemDefaultNeverAnnounces() {
        var tracker = AudioAvailabilityTracker()
        XCTAssertNil(tracker.check(configuredUID: nil, isAvailable: true))
        XCTAssertNil(tracker.check(configuredUID: nil, isAvailable: false))
        XCTAssertNil(tracker.check(configuredUID: nil, isAvailable: true))
    }

    // MARK: AppConfig fields

    func testAudioUIDsDecodeAndDefaultToNil() throws {
        let empty = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertNil(empty.audioInputUID)
        XCTAssertNil(empty.audioOutputUID)

        let set = try JSONDecoder().decode(AppConfig.self, from: Data(
            #"{"audioInputUID": "mic-uid", "audioOutputUID": "out-uid"}"#.utf8))
        XCTAssertEqual(set.audioInputUID, "mic-uid")
        XCTAssertEqual(set.audioOutputUID, "out-uid")

        // Empty strings normalize to nil like every other optional string.
        let blank = try JSONDecoder().decode(AppConfig.self, from: Data(
            #"{"audioInputUID": "", "audioOutputUID": ""}"#.utf8))
        XCTAssertNil(blank.audioInputUID)
        XCTAssertNil(blank.audioOutputUID)
    }

    func testAudioUIDsRoundTrip() throws {
        var config = AppConfig.defaultConfig()
        config.audioInputUID = "88-C9-E8:input"
        config.audioOutputUID = "BuiltInSpeakerDevice"
        let decoded = try JSONDecoder().decode(AppConfig.self,
                                               from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }
}
