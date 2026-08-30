import XCTest
import GameController
@testable import PowerUp

/// Pins the once-per-connection low-battery warning latch (#56): fires only
/// below the threshold while discharging, never twice per connection, resets
/// on reconnect, and ignores unpopulated readings and non-discharging states.
final class BatteryWarningLatchTests: XCTestCase {

    func testWarnsBelowThresholdWhileDischarging() {
        var latch = BatteryWarningLatch()
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
    }

    func testWarnsOnlyOncePerConnection() {
        var latch = BatteryWarningLatch()
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
        // The 60s poll repeats the same low value — no spam.
        XCTAssertFalse(latch.shouldWarn(level: 0.15, state: .discharging))
        XCTAssertFalse(latch.shouldWarn(level: 0.05, state: .discharging))
    }

    func testStaysLatchedEvenIfLevelRecovers() {
        var latch = BatteryWarningLatch()
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
        XCTAssertFalse(latch.shouldWarn(level: 0.5, state: .discharging))
        XCTAssertFalse(latch.shouldWarn(level: 0.1, state: .discharging))
    }

    func testResetRearmsTheWarning() {
        var latch = BatteryWarningLatch()
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
        latch.reset() // disconnect/reconnect
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
    }

    func testNeverWarnsUnlessDischarging() {
        var latch = BatteryWarningLatch()
        XCTAssertFalse(latch.shouldWarn(level: 0.15, state: .charging))
        XCTAssertFalse(latch.shouldWarn(level: 0.15, state: .full))
        XCTAssertFalse(latch.shouldWarn(level: 0.15, state: .unknown))
        // And none of those readings may consume the latch.
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
    }

    func testNoWarnAtOrAboveThreshold() {
        var latch = BatteryWarningLatch()
        XCTAssertFalse(latch.shouldWarn(level: BatteryWarningLatch.threshold, state: .discharging))
        XCTAssertFalse(latch.shouldWarn(level: 0.8, state: .discharging))
        // Boundary readings must not consume the latch either.
        XCTAssertTrue(latch.shouldWarn(level: 0.19, state: .discharging))
    }

    func testIgnoresUnpopulatedReadings() {
        var latch = BatteryWarningLatch()
        // GameController reports zeros briefly around connect.
        XCTAssertFalse(latch.shouldWarn(level: 0.0, state: .discharging))
        XCTAssertFalse(latch.shouldWarn(level: nil, state: .discharging))
        XCTAssertTrue(latch.shouldWarn(level: 0.15, state: .discharging))
    }
}
