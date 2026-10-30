import XCTest
import Network
@testable import PowerUp

/// End-to-end tests against a real listener on 127.0.0.1, using
/// URLSessionWebSocketTask as an independent client implementation. The only
/// tests that open a loopback port: RemoteListener's sockets carry out the
/// Rust core's connection policy (DESIGN v2.15), so every rule here runs
/// through the bridge. Each test binds its own random high port, never the
/// configured default, so a running PowerUp is never reached. Environments
/// that forbid loopback binds (some sandboxes) skip cleanly.
@MainActor
final class ProtocolServerTests: XCTestCase {

    private var listener: RemoteListener!
    private var port: UInt16 = 0
    private let token = "test-token-\(UUID().uuidString)"

    override func setUp() async throws {
        listener = RemoteListener()
        // A few attempts on random high ports avoids collisions with anything
        // already running on the machine.
        for _ in 0..<5 {
            repeat {
                port = UInt16.random(in: 20000...60000)
            } while Int(port) == AppConfig.defaultListenerPort
            listener.start(port: port, token: token)
            try await Task.sleep(nanoseconds: 200_000_000)
            if listener.isRunning { break }
        }
        try XCTSkipUnless(listener.isRunning,
                          "couldn't bind a loopback listener in this environment (\(listener.lastError ?? "no error"))")
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func openSocket(path: String = "/ws") -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(path)")!)
        task.resume()
        return task
    }

    private func sendJSON(_ text: String, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(text))
    }

    private func receiveJSON(over task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            XCTFail("expected a JSON text message, got \(message)")
            return [:]
        }
        return root
    }

    /// Writes `request` on a raw TCP connection and reads until the server
    /// closes it (or 5 s pass): what a hook script or a hand-written plugin
    /// sees, bytes URLSession would never send included.
    private func exchange(_ request: Data) async throws -> Data {
        let endpointPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let client = RawClient(NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp))
        return await withCheckedContinuation { continuation in
            client.exchange(request) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Handshake + auth

    func testHelloWithCorrectTokenGetsWelcomeAndSnapshot() async throws {
        listener.welcomeSnapshot = { [.status(.idle)] }

        let socket = openSocket()
        try await sendJSON(#"{"type":"hello","token":"\#(token)","protocol":0}"#, over: socket)

        let welcome = try await receiveJSON(over: socket)
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        XCTAssertEqual(welcome["protocol"] as? Int, 0)
        XCTAssertEqual(welcome["app"] as? String, "PowerUp")

        let snapshot = try await receiveJSON(over: socket)
        XCTAssertEqual(snapshot["type"] as? String, "status")
        XCTAssertEqual(snapshot["status"] as? String, "idle")

        socket.cancel(with: .normalClosure, reason: nil)
    }

    func testWrongTokenIsRefusedAndClosed() async throws {
        let socket = openSocket()
        try await sendJSON(#"{"type":"hello","token":"wrong","protocol":0}"#, over: socket)

        let refusal = try await receiveJSON(over: socket)
        XCTAssertEqual(refusal["type"] as? String, "error")
        XCTAssertEqual(refusal["code"] as? String, "auth_failed")

        // The server closes after the refusal: the next receive must fail.
        do {
            _ = try await socket.receive()
            XCTFail("expected the connection to be closed after a bad token")
        } catch {
            // expected
        }
    }

    func testIntentBeforeHelloIsRefused() async throws {
        let socket = openSocket()
        try await sendJSON(#"{"type":"intent","intent":"approve"}"#, over: socket)

        let refusal = try await receiveJSON(over: socket)
        XCTAssertEqual(refusal["code"] as? String, "not_authenticated")
        socket.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Intents and broadcast

    func testAuthenticatedIntentReachesTheCallbackAndBroadcastComesBack() async throws {
        var received: [Intent] = []
        let gotIntent = expectation(description: "intent delivered")
        listener.onIntent = { intent in
            received.append(intent)
            gotIntent.fulfill()
        }

        let socket = openSocket()
        try await sendJSON(#"{"type":"hello","token":"\#(token)"}"#, over: socket)
        _ = try await receiveJSON(over: socket)                       // welcome

        try await sendJSON(#"{"type":"intent","intent":"sendPrompt","text":"run the tests"}"#, over: socket)
        await fulfillment(of: [gotIntent], timeout: 5)
        XCTAssertEqual(received, [.sendPrompt("run the tests")])

        listener.broadcast(.status(.thinking))
        let status = try await receiveJSON(over: socket)
        XCTAssertEqual(status["type"] as? String, "status")
        XCTAssertEqual(status["status"] as? String, "thinking")

        socket.cancel(with: .normalClosure, reason: nil)
    }

    func testUnknownIntentGetsErrorButSessionSurvives() async throws {
        let socket = openSocket()
        try await sendJSON(#"{"type":"hello","token":"\#(token)"}"#, over: socket)
        _ = try await receiveJSON(over: socket)                       // welcome

        try await sendJSON(#"{"type":"intent","intent":"launchMissiles"}"#, over: socket)
        let error = try await receiveJSON(over: socket)
        XCTAssertEqual(error["code"] as? String, "unknown_intent")

        // Still connected and functional afterwards.
        try await sendJSON(#"{"type":"ping"}"#, over: socket)
        let pong = try await receiveJSON(over: socket)
        XCTAssertEqual(pong["type"] as? String, "pong")

        socket.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: The hook endpoint still works on the same port

    func testHookPostStillWorksAlongsideWebSocket() async throws {
        let gotHook = expectation(description: "hook delivered")
        listener.onEvent = { event in
            XCTAssertEqual(event.kind, .stop)
            XCTAssertEqual(event.text, "hello from a hook")
            gotHook.fulfill()
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-PowerUp-Token")
        request.httpBody = Data(#"{"hook_event_name":"Stop","last_assistant_message":"hello from a hook"}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        await fulfillment(of: [gotHook], timeout: 5)
    }

    func testSessionEndHookIsParsedAndDelivered() async throws {
        let gotHook = expectation(description: "SessionEnd delivered")
        listener.onEvent = { event in
            XCTAssertEqual(event.kind, .sessionEnd)
            XCTAssertEqual(event.sessionID, "s-123")
            XCTAssertEqual(event.text, "other")
            gotHook.fulfill()
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-PowerUp-Token")
        request.httpBody = Data(#"{"hook_event_name":"SessionEnd","session_id":"s-123","reason":"other"}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        await fulfillment(of: [gotHook], timeout: 5)
    }

    func testPostToolUseHeartbeatIsParsedAndDelivered() async throws {
        let gotHook = expectation(description: "PostToolUse delivered")
        listener.onEvent = { event in
            XCTAssertEqual(event.kind, .postToolUse)
            XCTAssertEqual(event.sessionID, "s-9")
            XCTAssertEqual(event.text, "Bash")
            gotHook.fulfill()
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-PowerUp-Token")
        request.httpBody = Data(#"{"hook_event_name":"PostToolUse","session_id":"s-9","tool_name":"Bash"}"#.utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        await fulfillment(of: [gotHook], timeout: 5)
    }

    func testABareLFHookPostIsAnsweredAndDelivered() async throws {
        // A real hook script once sent bare-LF lines (HK-254).
        let gotHook = expectation(description: "bare-LF hook delivered")
        listener.onEvent = { event in
            XCTAssertEqual(event.kind, .userPromptSubmit)
            XCTAssertEqual(event.text, "Run the tests")
            XCTAssertEqual(event.sessionID, "s-2")
            gotHook.fulfill()
        }
        let body = #"{"hook_event_name":"UserPromptSubmit","session_id":"s-2","prompt":"Run the tests"}"#
        let request = "POST /event HTTP/1.1\nHost: 127.0.0.1\nX-PowerUp-Token: \(token)\n"
            + "Content-Type: application/json\nContent-Length: \(body.utf8.count)\n\n\(body)"

        let response = try await exchange(Data(request.utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
        await fulfillment(of: [gotHook], timeout: 5)
    }

    func testABrowserOriginIsRefusedBeforeTheUpgrade() async throws {
        let request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Origin: https://evil.example\r\n\r\n"
        let response = try await exchange(Data(request.utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self),
                       "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    }

    func testWrongHookTokenIs403() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue("wrong", forHTTPHeaderField: "X-PowerUp-Token")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }
}

/// One raw TCP exchange; its state lives on its own queue.
private final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ProtocolServerTests.RawClient")
    private var received = Data()
    private var done: ((Data) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func exchange(_ request: Data, done: @escaping (Data) -> Void) {
        queue.async { [self] in
            self.done = done
            connection.stateUpdateHandler = { [self] state in
                if case .failed = state { finish() }
            }
            connection.start(queue: queue)
            connection.send(content: request, completion: .contentProcessed { _ in })
            read()
            queue.asyncAfter(deadline: .now() + 5) { [self] in finish() }
        }
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { received.append(data) }
            if isComplete || error != nil { finish() } else { read() }
        }
    }

    private func finish() {
        guard let done else { return }
        self.done = nil
        connection.cancel()
        done(received)
    }
}
