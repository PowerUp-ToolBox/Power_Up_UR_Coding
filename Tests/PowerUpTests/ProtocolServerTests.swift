import XCTest
@testable import PowerUp

/// End-to-end tests against a real listener on 127.0.0.1, using
/// URLSessionWebSocketTask as an independent client implementation.
/// Environments that forbid loopback binds (some sandboxes) skip cleanly.
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
            port = UInt16.random(in: 20000...60000)
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

    // MARK: Handshake + auth

    func testHelloWithCorrectTokenGetsWelcomeAndSnapshot() async throws {
        listener.welcomeSnapshot = { [PowerUpProtocol.status(.idle)] }

        let socket = openSocket()
        try await sendJSON(#"{"type":"hello","token":"\#(token)","protocol":0}"#, over: socket)

        let welcome = try await receiveJSON(over: socket)
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        XCTAssertEqual(welcome["protocol"] as? Int, PowerUpProtocol.version)
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

        listener.broadcast(PowerUpProtocol.status(.thinking))
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

    func testWrongHookTokenIs403() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue("wrong", forHTTPHeaderField: "X-PowerUp-Token")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }
}
