import XCTest
import PowerUpCore

/// The hooks half of the bridge (slice 2.5): optional byte buffers in, an
/// enum carrying bytes or a nested enum out, through the generated
/// functions. Only literal settings text is used; no file is touched.
final class CoreHooksBridgeTests: XCTestCase {

    private let path = "/tmp/x y/powerup-hook.sh"

    func testAnInstallRoundTrips() throws {
        guard case .write(let json) = try hookInstallEdit(settings: nil, scriptPath: path) else {
            return XCTFail("a fresh install writes the file")
        }
        XCTAssertEqual(try hookInstallEdit(settings: json, scriptPath: path), .unchanged)
        XCTAssertTrue(try hooksInstalled(settings: json, scriptPath: path))
        let script = Data(try hookScriptBody(port: 48738, token: "tok").utf8)
        XCTAssertEqual(try hookInstallState(settings: json, scriptPath: path, scriptOnDisk: script,
                                            port: 48738, token: "tok"), .installed)
        XCTAssertEqual(try hookInstallState(settings: json, scriptPath: path, scriptOnDisk: nil,
                                            port: 48738, token: "tok"), .outOfDate)
        XCTAssertEqual(try hookUninstallEdit(settings: json, scriptPath: path), .write(json: Data("{}".utf8)))
    }

    func testRefusalsNameTheirReason() throws {
        XCTAssertEqual(try hookInstallEdit(settings: Data("[]".utf8), scriptPath: path),
                       .refused(refusal: .invalidJson))
        XCTAssertEqual(try hookInstallEdit(settings: Data(#"{"hooks":{"Notification":"x"}}"#.utf8), scriptPath: path),
                       .refused(refusal: .eventNotAnArray(event: "Notification")))
        XCTAssertEqual(try hookUninstallEdit(settings: Data(#"{"hooks":null}"#.utf8), scriptPath: path),
                       .refused(refusal: .hooksNotAnObject))
        XCTAssertEqual(try hookUninstallEdit(settings: nil, scriptPath: path), .unchanged)
    }

    func testEventsCommandAndScript() throws {
        XCTAssertEqual(try hookEvents(), ["Stop", "UserPromptSubmit", "Notification", "SessionEnd", "PostToolUse"])
        XCTAssertEqual(try hookCommand(scriptPath: "/a'b"), #"'/a'\''b'"#)
        XCTAssertTrue(try hookScriptBody(port: 70000, token: "t").contains("127.0.0.1:65535/event"))
    }
}
