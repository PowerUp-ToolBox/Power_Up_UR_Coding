import Foundation

/// Message vocabulary and handshake rules of the PowerUp protocol v0.
/// The spec is `docs/protocol.md` — the two must change together.
///
/// Everything here is pure: the listener owns sockets, this file owns bytes
/// and shapes, and the tests pin both.
enum PowerUpProtocol {

    /// Pre-1.0 protocol; may change incompatibly between app versions.
    static let version = 0

    // MARK: - Upgrade handshake

    enum UpgradeDecision: Equatable {
        case accept(acceptKey: String)
        case reject(status: Int, reason: String)
    }

    /// Decides what to do with a request aimed at the WebSocket endpoint.
    /// Returns nil when the request isn't for `/ws` at all (plain HTTP
    /// handling proceeds). Security posture (see docs/protocol.md):
    /// a request carrying any non-empty `Origin` header is refused — browsers
    /// always send one, which shuts the cross-site-WebSocket-hijacking door
    /// until an explicit allowlist is designed.
    static func upgradeDecision(method: String,
                                path: String,
                                header: (String) -> String?) -> UpgradeDecision? {
        guard path == "/ws" else { return nil }

        guard method == "GET" else {
            return .reject(status: 405, reason: "Method Not Allowed")
        }
        let upgrade = (header("upgrade") ?? "").lowercased()
        let connection = (header("connection") ?? "").lowercased()
        guard upgrade.contains("websocket"), connection.contains("upgrade") else {
            return .reject(status: 400, reason: "Bad Request")
        }
        if let origin = header("origin"), !origin.trimmingCharacters(in: .whitespaces).isEmpty {
            return .reject(status: 403, reason: "Forbidden")
        }
        guard (header("sec-websocket-version") ?? "") == "13" else {
            return .reject(status: 426, reason: "Upgrade Required")
        }
        guard let key = header("sec-websocket-key")?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty else {
            return .reject(status: 400, reason: "Bad Request")
        }
        return .accept(acceptKey: WebSocketFraming.acceptKey(forClientKey: key))
    }

    // MARK: - Client → server messages

    enum ClientMessage: Equatable {
        case hello(token: String)
        case intent(Intent)
        case ping
    }

    enum ClientMessageFailure: Error, Equatable {
        case malformed
        case unknownType(String)
        case badHello
        case unsupportedProtocol(Int)
        case unknownIntent(String)

        var code: String {
            switch self {
            case .malformed: return "malformed"
            case .unknownType: return "unknown_type"
            case .badHello: return "bad_hello"
            case .unsupportedProtocol: return "unsupported_protocol"
            case .unknownIntent: return "unknown_intent"
            }
        }

        var message: String {
            switch self {
            case .malformed:
                return "Messages must be single JSON objects with a \"type\" field."
            case .unknownType(let type):
                return "Unknown message type \"\(type)\"."
            case .badHello:
                return "hello must carry a non-empty \"token\"."
            case .unsupportedProtocol(let requested):
                return "This server speaks protocol \(PowerUpProtocol.version); you asked for \(requested)."
            case .unknownIntent(let name):
                return "Unknown or disallowed intent \"\(name)\" (see docs/protocol.md for the allowed set)."
            }
        }
    }

    static func parseClientMessage(_ data: Data) -> Result<ClientMessage, ClientMessageFailure> {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = parsed as? [String: Any],
              let type = root["type"] as? String else {
            return .failure(.malformed)
        }

        switch type {
        case "hello":
            guard let token = root["token"] as? String, !token.isEmpty else {
                return .failure(.badHello)
            }
            let requested = (root["protocol"] as? NSNumber)?.intValue ?? version
            guard requested == version else {
                return .failure(.unsupportedProtocol(requested))
            }
            return .success(.hello(token: token))

        case "intent":
            let name = (root["intent"] as? String) ?? ""
            guard let intent = IntentMapper.intent(forProtocolName: name,
                                                   text: root["text"] as? String) else {
                return .failure(.unknownIntent(name))
            }
            return .success(.intent(intent))

        case "ping":
            return .success(.ping)

        default:
            return .failure(.unknownType(type))
        }
    }

    // MARK: - Server → client messages

    static func welcome(appVersion: String) -> [String: Any] {
        ["type": "welcome", "protocol": version, "app": "PowerUp", "version": appVersion]
    }

    static func statusName(_ status: AppStatus) -> String {
        switch status {
        case .noController: return "noController"
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        }
    }

    static func status(_ status: AppStatus) -> [String: Any] {
        ["type": "status", "status": statusName(status)]
    }

    static func transcript(_ entry: TranscriptEntry) -> [String: Any] {
        ["type": "transcript",
         "entry": ["id": entry.id.uuidString,
                   "kind": entry.kind.rawValue,
                   "text": entry.text,
                   "date": entry.date.timeIntervalSince1970]]
    }

    /// `model` is the configured alias ("default" = the adapter decides);
    /// `liveModel` is what the running session actually reports, when known.
    static func session(model: String,
                        liveModel: String?,
                        effort: String,
                        permissionMode: String,
                        controlMode: String,
                        sessionID: String?,
                        costUSD: Double,
                        tokens: Int = 0) -> [String: Any] {
        var message: [String: Any] = [
            "type": "session",
            "model": model,
            "effort": effort,
            "permissionMode": permissionMode,
            "controlMode": controlMode,
            "costUSD": costUSD
        ]
        if tokens > 0 { message["tokens"] = tokens }
        if let liveModel, !liveModel.isEmpty { message["liveModel"] = liveModel }
        if let sessionID, !sessionID.isEmpty { message["sessionID"] = sessionID }
        return message
    }

    static func pong() -> [String: Any] {
        ["type": "pong"]
    }

    static func error(code: String, message: String) -> [String: Any] {
        ["type": "error", "code": code, "message": message]
    }

    /// One compact JSON object — never contains a raw newline, so a debugging
    /// client reading line-wise stays happy too.
    static func encode(_ message: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(message) else { return nil }
        return try? JSONSerialization.data(withJSONObject: message, options: [])
    }
}
