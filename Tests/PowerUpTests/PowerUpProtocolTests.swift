import XCTest
@testable import PowerUp

final class PowerUpProtocolTests: XCTestCase {

    // MARK: Upgrade decisions

    private func decide(method: String = "GET",
                        path: String = "/ws",
                        headers: [String: String]) -> PowerUpProtocol.UpgradeDecision? {
        PowerUpProtocol.upgradeDecision(method: method, path: path) { headers[$0] }
    }

    private let goodHeaders = [
        "upgrade": "websocket",
        "connection": "Upgrade",
        "sec-websocket-version": "13",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
    ]

    func testValidUpgradeIsAcceptedWithCorrectKey() {
        XCTAssertEqual(decide(headers: goodHeaders),
                       .accept(acceptKey: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    }

    func testNonWSPathsFallThroughToPlainHTTP() {
        XCTAssertNil(decide(path: "/event", headers: goodHeaders))
        XCTAssertNil(decide(path: "/", headers: goodHeaders))
    }

    func testWrongMethodIsRejected() {
        XCTAssertEqual(decide(method: "POST", headers: goodHeaders),
                       .reject(status: 405, reason: "Method Not Allowed"))
    }

    func testMissingUpgradeHeadersAreRejected() {
        var headers = goodHeaders
        headers["upgrade"] = nil
        XCTAssertEqual(decide(headers: headers), .reject(status: 400, reason: "Bad Request"))
    }

    func testBrowserOriginIsRejected() {
        // CSWSH defense: browsers always send Origin; native clients don't.
        var headers = goodHeaders
        headers["origin"] = "https://evil.example"
        XCTAssertEqual(decide(headers: headers), .reject(status: 403, reason: "Forbidden"))
    }

    func testWrongWebSocketVersionIsRejected() {
        var headers = goodHeaders
        headers["sec-websocket-version"] = "8"
        XCTAssertEqual(decide(headers: headers), .reject(status: 426, reason: "Upgrade Required"))
    }

    func testMissingKeyIsRejected() {
        var headers = goodHeaders
        headers["sec-websocket-key"] = "  "
        XCTAssertEqual(decide(headers: headers), .reject(status: 400, reason: "Bad Request"))
    }

    // MARK: Client messages

    private func parse(_ json: String) -> Result<PowerUpProtocol.ClientMessage, PowerUpProtocol.ClientMessageFailure> {
        PowerUpProtocol.parseClientMessage(Data(json.utf8))
    }

    func testHelloParses() {
        XCTAssertEqual(parse(#"{"type":"hello","token":"secret","protocol":0}"#),
                       .success(.hello(token: "secret")))
        XCTAssertEqual(parse(#"{"type":"hello","token":"secret"}"#),
                       .success(.hello(token: "secret")),
                       "protocol defaults to the current version")
    }

    func testHelloWithoutTokenFails() {
        XCTAssertEqual(parse(#"{"type":"hello"}"#), .failure(.badHello))
        XCTAssertEqual(parse(#"{"type":"hello","token":""}"#), .failure(.badHello))
    }

    func testFutureProtocolVersionIsRefused() {
        XCTAssertEqual(parse(#"{"type":"hello","token":"t","protocol":7}"#),
                       .failure(.unsupportedProtocol(7)))
    }

    func testIntentMessagesParse() {
        XCTAssertEqual(parse(#"{"type":"intent","intent":"approve"}"#), .success(.intent(.approve)))
        XCTAssertEqual(parse(#"{"type":"intent","intent":"sendPrompt","text":"hi"}"#),
                       .success(.intent(.sendPrompt("hi"))))
    }

    func testUnknownIntentFailsWithoutActing() {
        XCTAssertEqual(parse(#"{"type":"intent","intent":"launchMissiles"}"#),
                       .failure(.unknownIntent("launchMissiles")))
        XCTAssertEqual(parse(#"{"type":"intent"}"#), .failure(.unknownIntent("")))
    }

    func testPingAndGarbage() {
        XCTAssertEqual(parse(#"{"type":"ping"}"#), .success(.ping))
        XCTAssertEqual(parse(#"{"type":"mystery"}"#), .failure(.unknownType("mystery")))
        XCTAssertEqual(parse("not json"), .failure(.malformed))
        XCTAssertEqual(parse("[1,2]"), .failure(.malformed))
    }

    // MARK: Server messages

    func testTranscriptMessageShape() throws {
        let entry = TranscriptEntry(kind: .assistant, text: "All tests pass.")
        let message = PowerUpProtocol.transcript(entry)
        let data = try XCTUnwrap(PowerUpProtocol.encode(message))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "transcript")
        let encoded = try XCTUnwrap(root["entry"] as? [String: Any])
        XCTAssertEqual(encoded["kind"] as? String, "assistant")
        XCTAssertEqual(encoded["text"] as? String, "All tests pass.")
        XCTAssertEqual(encoded["id"] as? String, entry.id.uuidString)
        XCTAssertNotNil(encoded["date"] as? Double)
    }

    func testSessionMessageOmitsEmptyOptionals() {
        let message = PowerUpProtocol.session(model: "default", liveModel: nil, effort: "high",
                                              permissionMode: "acceptEdits", controlMode: "builtin",
                                              sessionID: nil, costUSD: 0)
        XCTAssertNil(message["liveModel"])
        XCTAssertNil(message["sessionID"])
        XCTAssertEqual(message["model"] as? String, "default")
    }

    func testStatusNamesAreStable() {
        // Wire names are API — renaming an AppStatus case must not leak out.
        XCTAssertEqual(PowerUpProtocol.statusName(.noController), "noController")
        XCTAssertEqual(PowerUpProtocol.statusName(.idle), "idle")
        XCTAssertEqual(PowerUpProtocol.statusName(.listening), "listening")
        XCTAssertEqual(PowerUpProtocol.statusName(.thinking), "thinking")
        XCTAssertEqual(PowerUpProtocol.statusName(.speaking), "speaking")
    }

    func testEncodedMessagesAreSingleLine() throws {
        let data = try XCTUnwrap(PowerUpProtocol.encode(
            PowerUpProtocol.transcript(TranscriptEntry(kind: .user, text: "line one\nline two"))))
        XCTAssertFalse(data.contains(0x0A), "raw newlines would break line-wise debug clients")
    }
}
