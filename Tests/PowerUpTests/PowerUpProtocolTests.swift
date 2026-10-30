import XCTest
@testable import PowerUp

/// The protocol's handshake and messages through the bridge (slice 2.6,
/// DESIGN v2.15): the core decides the upgrade from a request's bytes, reads
/// a client's text frame and writes every server message.
final class PowerUpProtocolTests: XCTestCase {

    // MARK: Upgrade decisions

    private func decide(method: String = "GET",
                        path: String = "/ws",
                        headers: [String: String]) -> CoreBridge.Handshake? {
        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        return CoreBridge.handshake(Data(request.utf8))
    }

    private let goodHeaders = [
        "upgrade": "websocket",
        "connection": "Upgrade",
        "sec-websocket-version": "13",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
    ]

    func testValidUpgradeIsAcceptedWithCorrectKey() {
        XCTAssertEqual(decide(headers: goodHeaders),
                       .accept(method: "GET", path: "/ws", acceptKey: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    }

    func testNonWSPathsFallThroughToPlainHTTP() {
        XCTAssertEqual(decide(path: "/event", headers: goodHeaders), .notWebSocket(method: "GET", path: "/event"))
        XCTAssertEqual(decide(path: "/", headers: goodHeaders), .notWebSocket(method: "GET", path: "/"))
    }

    func testWrongMethodIsRejected() {
        XCTAssertEqual(decide(method: "POST", headers: goodHeaders),
                       .refuse(method: "POST", path: "/ws", status: 405, reason: "Method Not Allowed"))
    }

    func testMissingUpgradeHeadersAreRejected() {
        var headers = goodHeaders
        headers["upgrade"] = nil
        XCTAssertEqual(decide(headers: headers), .refuse(method: "GET", path: "/ws", status: 400, reason: "Bad Request"))
    }

    func testBrowserOriginIsRejected() {
        // CSWSH defense: browsers always send Origin; native clients don't.
        var headers = goodHeaders
        headers["origin"] = "https://evil.example"
        XCTAssertEqual(decide(headers: headers), .refuse(method: "GET", path: "/ws", status: 403, reason: "Forbidden"))
    }

    func testWrongWebSocketVersionIsRejected() {
        var headers = goodHeaders
        headers["sec-websocket-version"] = "8"
        XCTAssertEqual(decide(headers: headers),
                       .refuse(method: "GET", path: "/ws", status: 426, reason: "Upgrade Required"))
    }

    func testMissingKeyIsRejected() {
        var headers = goodHeaders
        headers["sec-websocket-key"] = "  "
        XCTAssertEqual(decide(headers: headers), .refuse(method: "GET", path: "/ws", status: 400, reason: "Bad Request"))
    }

    // MARK: Client messages

    private func parse(_ json: String) -> Result<CoreBridge.ClientMessage, CoreBridge.ClientMessageFailure>? {
        CoreBridge.clientMessage(Data(json.utf8))
    }

    /// The failure's wire code, or nil for a message that reads.
    private func failureCode(_ json: String) -> String? {
        guard case .failure(let failure)? = parse(json) else { return nil }
        return failure.code
    }

    func testHelloParses() {
        XCTAssertEqual(parse(#"{"type":"hello","token":"secret","protocol":0}"#),
                       .success(.hello(token: "secret")))
        XCTAssertEqual(parse(#"{"type":"hello","token":"secret"}"#),
                       .success(.hello(token: "secret")),
                       "protocol defaults to the current version")
    }

    func testHelloWithoutTokenFails() {
        XCTAssertEqual(failureCode(#"{"type":"hello"}"#), "bad_hello")
        XCTAssertEqual(failureCode(#"{"type":"hello","token":""}"#), "bad_hello")
    }

    func testFutureProtocolVersionIsRefused() {
        XCTAssertEqual(parse(#"{"type":"hello","token":"t","protocol":7}"#),
                       .failure(CoreBridge.ClientMessageFailure(
                        code: "unsupported_protocol", message: "This server speaks protocol 0; you asked for 7.")))
    }

    func testIntentMessagesParse() {
        XCTAssertEqual(parse(#"{"type":"intent","intent":"approve"}"#), .success(.intent(.approve)))
        XCTAssertEqual(parse(#"{"type":"intent","intent":"sendPrompt","text":"hi"}"#),
                       .success(.intent(.sendPrompt("hi"))))
    }

    func testUnknownIntentFailsWithoutActing() {
        XCTAssertEqual(parse(#"{"type":"intent","intent":"launchMissiles"}"#),
                       .failure(CoreBridge.ClientMessageFailure(
                        code: "unknown_intent",
                        message: #"Unknown or disallowed intent "launchMissiles" (see docs/protocol.md for the allowed set)."#)))
        XCTAssertEqual(parse(#"{"type":"intent"}"#),
                       .failure(CoreBridge.ClientMessageFailure(
                        code: "unknown_intent",
                        message: #"Unknown or disallowed intent "" (see docs/protocol.md for the allowed set)."#)))
    }

    func testPingAndGarbage() {
        XCTAssertEqual(parse(#"{"type":"ping"}"#), .success(.ping))
        XCTAssertEqual(parse(#"{"type":"mystery"}"#),
                       .failure(CoreBridge.ClientMessageFailure(code: "unknown_type",
                                                                message: #"Unknown message type "mystery"."#)))
        XCTAssertEqual(failureCode("not json"), "malformed")
        XCTAssertEqual(failureCode("[1,2]"), "malformed")
    }

    // MARK: Server messages

    /// The message's frame text read back as JSON.
    private func encoded(_ message: CoreBridge.ServerMessage) throws -> [String: Any] {
        let text = try XCTUnwrap(CoreBridge.protocolEncode(message))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func session(tokens: Int) -> CoreBridge.ServerMessage {
        .session(CoreBridge.SessionMessage(model: "default", liveModel: nil, effort: "high",
                                           permissionMode: "acceptEdits", controlMode: "builtin",
                                           sessionID: nil, costUSD: 0, tokens: tokens))
    }

    func testTranscriptMessageShape() throws {
        let entry = TranscriptEntry(kind: .assistant, text: "All tests pass.")
        let root = try encoded(.transcript(entry))
        XCTAssertEqual(root["type"] as? String, "transcript")
        let encoded = try XCTUnwrap(root["entry"] as? [String: Any])
        XCTAssertEqual(encoded["kind"] as? String, "assistant")
        XCTAssertEqual(encoded["text"] as? String, "All tests pass.")
        XCTAssertEqual(encoded["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(try XCTUnwrap(encoded["date"] as? Double), entry.date.timeIntervalSince1970, accuracy: 1e-6)
    }

    func testSessionMessageOmitsEmptyOptionals() throws {
        let message = try encoded(session(tokens: 0))
        XCTAssertNil(message["liveModel"])
        XCTAssertNil(message["sessionID"])
        XCTAssertNil(message["tokens"], "zero tokens must be omitted, not sent as 0")
        XCTAssertEqual(message["model"] as? String, "default")
    }

    func testSessionMessageCarriesTokensWhenKnown() throws {
        XCTAssertEqual(try encoded(session(tokens: 55888))["tokens"] as? Int, 55888)
    }

    func testStatusNamesAreStable() throws {
        // Wire names are API — renaming an AppStatus case must not leak out.
        let names: [(AppStatus, String)] = [(.noController, "noController"), (.idle, "idle"),
                                            (.listening, "listening"), (.thinking, "thinking"),
                                            (.speaking, "speaking")]
        for (status, name) in names {
            XCTAssertEqual(CoreBridge.protocolEncode(.status(status)), #"{"type":"status","status":"\#(name)"}"#)
        }
    }

    func testEncodedMessagesAreSingleLine() throws {
        let text = try XCTUnwrap(CoreBridge.protocolEncode(
            .transcript(TranscriptEntry(kind: .user, text: "line one\nline two"))))
        XCTAssertFalse(text.contains("\n"), "raw newlines would break line-wise debug clients")
    }
}
