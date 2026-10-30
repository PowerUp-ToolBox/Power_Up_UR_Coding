import XCTest
import PowerUpCore

/// The protocol half of the bridge (slice 2.6): client messages, the name
/// table, server messages, the handshake and the frames through the
/// generated functions, and the `CoreListener` object keeping the bind and
/// its connections between calls. No socket is opened.
final class CoreProtocolBridgeTests: XCTestCase {

    /// A client text frame, masked with a zero key so the payload reads as
    /// written.
    private func clientText(_ text: String) -> Data {
        let payload = Data(text.utf8)
        precondition(payload.count < 126)
        return Data([0x81, 0x80 | UInt8(payload.count), 0, 0, 0, 0]) + payload
    }

    private let upgrade = Data("""
        GET /ws HTTP/1.1\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """.utf8)

    func testClientMessagesAndTheNameTable() throws {
        XCTAssertEqual(try protocolClientMessage(payload: Data(#"{"type":"hello","token":"t"}"#.utf8)),
                       .message(message: .hello(token: "t")))
        XCTAssertEqual(try protocolClientMessage(payload: Data(#"{"type":"intent","intent":"sendPrompt","text":" hi "}"#.utf8)),
                       .message(message: .intent(intent: .sendPrompt(prompt: "hi"))))
        XCTAssertEqual(try protocolClientMessage(payload: Data(#"{"type":"nope"}"#.utf8)),
                       .failure(failure: CoreClientMessageFailure(code: "unknown_type",
                                                                  message: #"Unknown message type "nope"."#)))
        XCTAssertEqual(try protocolClientMessage(payload: Data([0xFF])),
                       .failure(failure: CoreClientMessageFailure(
                        code: "malformed", message: #"Messages must be single JSON objects with a "type" field."#)))
        XCTAssertEqual(try protocolIntent(name: "toggleTTS", text: nil), .toggleTts)
        XCTAssertNil(try protocolIntent(name: "beginVoiceCapture", text: nil))
        XCTAssertNil(try protocolIntent(name: "sendPrompt", text: "  "))
    }

    func testServerMessagesEncodeInTheFixedOrder() throws {
        XCTAssertEqual(try protocolEncode(message: .welcome(appVersion: "1.0")),
                       #"{"type":"welcome","protocol":0,"app":"PowerUp","version":"1.0"}"#)
        XCTAssertEqual(try protocolEncode(message: .status(status: .thinking)), #"{"type":"status","status":"thinking"}"#)
        let entry = CoreTranscriptEntry(id: "3F2504E0-4F89-41D3-9A0C-0305E82C3301", kind: .error,
                                        text: "a/b", dateSeconds: 0.0421)
        XCTAssertEqual(try protocolEncode(message: .transcript(entry: entry)),
                       #"{"type":"transcript","entry":{"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","kind":"error","text":"a\/b","date":0.042099999999999999}}"#)
        let session = CoreSessionMessage(model: "default", liveModel: nil, effort: "high", permissionMode: "plan",
                                         controlMode: "local", sessionId: "s1", costUsd: 1, tokens: 0)
        XCTAssertEqual(try protocolEncode(message: .session(session: session)),
                       #"{"type":"session","model":"default","effort":"high","permissionMode":"plan","controlMode":"local","costUSD":1,"sessionID":"s1"}"#)
        let unspellable = CoreSessionMessage(model: "default", liveModel: nil, effort: "high", permissionMode: "plan",
                                             controlMode: "local", sessionId: nil, costUsd: .nan, tokens: 0)
        XCTAssertNil(try protocolEncode(message: .session(session: unspellable)))
        XCTAssertEqual(try protocolEncode(message: .pong), #"{"type":"pong"}"#)
        XCTAssertEqual(try protocolEncode(message: .error(code: "server_busy", message: "x")),
                       #"{"type":"error","code":"server_busy","message":"x"}"#)
    }

    func testTheHandshakeAndTheAcceptKey() throws {
        XCTAssertEqual(try protocolHandshake(request: Data("GET /ws HTTP/1.1\r\n".utf8)), .incomplete)
        XCTAssertEqual(try protocolHandshake(request: Data("post /event?x HTTP/1.1\nA: b\n\n".utf8)),
                       .notWebSocket(method: "POST", path: "/event"))
        XCTAssertEqual(try protocolHandshake(request: upgrade),
                       .accept(method: "GET", path: "/ws", acceptKey: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        var browser = upgrade.dropLast(2)
        browser += Data("Origin: https://example.com\r\n\r\n".utf8)
        XCTAssertEqual(try protocolHandshake(request: Data(browser)),
                       .refuse(method: "GET", path: "/ws", status: 403, reason: "Forbidden"))
        XCTAssertEqual(try protocolAcceptKey(clientKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testFramesDecodeAndEncode() throws {
        XCTAssertEqual(try protocolDecodeFrames(buffer: clientText("Hi") + Data([0x89]), maxPayload: 1024),
                       .frames(frames: [CoreFrame(opcode: .text, payload: Data("Hi".utf8))], consumed: 8))
        XCTAssertEqual(try protocolDecodeFrames(buffer: clientText("Hi") + Data([0x81, 0x00]), maxPayload: 1024),
                       .violation, "an unmasked frame refuses the whole buffer")
        XCTAssertEqual(try protocolEncodeFrame(opcode: .pong, payload: Data("p".utf8)), Data([0x8A, 0x01, 0x70]))
        XCTAssertEqual(try protocolEncodeText(payload: Data("ok".utf8)), Data([0x81, 0x02, 0x6F, 0x6B]))
        XCTAssertEqual(try protocolEncodeClose(code: 4001), Data([0x88, 0x02, 0x0F, 0xA1]))
    }

    /// A hook post is answered 204 before it is delivered (HK-247), from a
    /// bare-LF head (HK-254).
    func testTheListenerAnswersAHookPostBeforeDeliveringIt() throws {
        let listener = try CoreListener()
        XCTAssertEqual(try listener.start(port: 48738, token: "secret"), [.listen(generation: 2, port: 48738)])
        XCTAssertEqual(try listener.bindReady(generation: 2),
                       [.publish(status: CoreListenerStatus(running: true, problem: nil))])
        XCTAssertEqual(try listener.accepted(generation: 1), [.refuse], "a torn-down listener's socket")
        XCTAssertEqual(try listener.accepted(generation: 2),
                       [.admit(connection: 1), .armIdleDeadline(connection: 1, seconds: 15)])
        let body = #"{"hook_event_name":"UserPromptSubmit","prompt":"hi","cwd":" "}"#
        let post = "POST /event HTTP/1.1\nX-PowerUp-Token: secret\nContent-Length: \(body.utf8.count)\n\n\(body)"
        XCTAssertEqual(try listener.received(connection: 1, bytes: Data(post.utf8)), [
            .send(connection: 1, bytes: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)),
            .close(connection: 1),
            .deliverHook(generation: 2, hook: CoreHookPost(kind: .userPromptSubmit, text: "hi", sessionId: nil, cwd: nil))
        ])
        XCTAssertEqual(try listener.closed(connection: 1), [.cancel(connection: 1)])
        XCTAssertEqual(try listener.connectionCount(), 0)
    }

    /// The hello gate, the welcome, an intent and a broadcast through the
    /// object; the idle deadline spares the authenticated client (HK-255).
    func testTheListenerAuthenticatesAProtocolClient() throws {
        let listener = try CoreListener()
        _ = try listener.start(port: 48738, token: "secret")
        _ = try listener.bindReady(generation: 2)
        _ = try listener.accepted(generation: 2)
        let effects = try listener.received(connection: 1, bytes: upgrade + clientText(#"{"type":"hello","token":"secret"}"#))
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.last, .welcome(connection: 1))
        XCTAssertEqual(try listener.authenticatedCount(), 1)
        let welcome = try listener.welcome(connection: 1, appVersion: "1.0", snapshot: [.status(status: .idle)])
        XCTAssertEqual(welcome.count, 2, "the welcome, then the snapshot")
        XCTAssertEqual(try listener.received(connection: 1, bytes: clientText(#"{"type":"intent","intent":"approve"}"#)),
                       [.deliverIntent(generation: 2, intent: .approve)])
        XCTAssertEqual(try listener.broadcast(message: .pong),
                       [.broadcast(connections: [1], bytes: Data([0x81, 15]) + Data(#"{"type":"pong"}"#.utf8))])
        XCTAssertEqual(try listener.deadlineFired(connection: 1), [])

        // A wrong token on a second client: auth_failed, then close 4001.
        _ = try listener.accepted(generation: 2)
        let refused = try listener.received(connection: 2, bytes: upgrade + clientText(#"{"type":"hello","token":"x"}"#))
        XCTAssertEqual(refused.suffix(2), [.send(connection: 2, bytes: Data([0x88, 0x02, 0x0F, 0xA1])), .close(connection: 2)])
    }

    func testTheBindRetriesAndReportsItsProblems() throws {
        let listener = try CoreListener()
        _ = try listener.start(port: 48738, token: "secret")
        let failed = try listener.bindFailed(generation: 2, error: .addressInUse)
        XCTAssertEqual(failed.last, .scheduleBindRetry(generation: 3, seconds: 2))
        XCTAssertEqual(try listener.status().problem,
                       "Port 48738 is already in use — pick a different port in Settings → Remote.")
        // The retry starts again: the problem clears, and the start's own
        // stop and bind each bump the generation.
        XCTAssertEqual(try listener.retryFired(generation: 3), [
            .publish(status: CoreListenerStatus(running: false, problem: nil)),
            .listen(generation: 5, port: 48738)
        ])
        _ = try listener.bindWaiting(generation: 5, error: .other(description: "nope"))
        XCTAssertEqual(try listener.status(),
                       CoreListenerStatus(running: false, problem: "Listener problem on port 48738: nope"))
        XCTAssertEqual(try listener.listenRefused(generation: 5, detail: "denied"),
                       [.publish(status: CoreListenerStatus(running: false,
                                                            problem: "Couldn't listen on 127.0.0.1:48738 — denied"))])
        XCTAssertEqual(try listener.bindCancelled(generation: 5), [])
        XCTAssertEqual(try listener.endOfStream(connection: 9), [])
        XCTAssertEqual(try listener.start(port: 80, token: "secret"),
                       [.publish(status: CoreListenerStatus(
                        running: false, problem: "Port 80 isn't a usable port number — pick one between 1024 and 65535."))])
        XCTAssertEqual(try listener.stop(), [])
        XCTAssertGreaterThan(try listener.generation(), 5)
    }

    func testTheLimitsAreTheSpecConstants() throws {
        XCTAssertEqual(try listenerLimits(), CoreListenerLimits(
            maxConnections: 32, maxAuthenticated: 16, idleDeadlineSeconds: 15, maxHeaderBytes: 16 * 1024,
            maxBodyBytes: 4 * 1024 * 1024, maxPayloadBytes: 1024 * 1024, maxWebsocketBufferBytes: 2 * 1024 * 1024,
            receiveChunkBytes: 32 * 1024, maxBindRetries: 3, bindRetryStepSeconds: 2, minPort: 1024))
    }
}
