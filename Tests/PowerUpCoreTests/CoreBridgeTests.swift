import XCTest
import PowerUpCore

/// The uniffi bridge into the Rust core (stage 2.1): a value round-trips,
/// a core error arrives as a Swift error, and a core panic arrives as an
/// error instead of taking down the process.
final class CoreBridgeTests: XCTestCase {

    func testEchoRoundTripsText() throws {
        XCTAssertEqual(try probeEcho(text: "hello 世界"), "hello 世界")
    }

    func testACoreErrorArrivesAsASwiftError() {
        XCTAssertThrowsError(try probeFail(message: "no microphone")) { error in
            XCTAssertEqual(error as? CoreBridgeError, .Failed(message: "no microphone"))
        }
    }

    func testACorePanicArrivesAsAnError() {
        XCTAssertThrowsError(try probePanic(message: "boom")) { error in
            XCTAssertEqual(error as? CoreBridgeError, .Panicked(message: "boom"))
        }
    }
}
