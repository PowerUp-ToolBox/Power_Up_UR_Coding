import Foundation
import PowerUpCore

/// The PowerUp protocol's messages and frames (slice 2.6, DESIGN v2.15):
/// the core owns how a client's text frame reads, the protocol name table,
/// every server message as the text of its frame, the handshake a request
/// head comes to, the accept key and the RFC 6455 frames. The listener's
/// machine (CoreBridgeListener.swift) runs all of them itself; the app
/// builds server messages for it and the protocol name table answers
/// directly. As in CoreBridge.swift, generated names are written
/// `PowerUpCore.…` wherever a wrapper shares them.
extension CoreBridge {

    // MARK: Client messages

    /// A message a client sent.
    enum ClientMessage: Equatable {
        case hello(token: String)
        case intent(Intent)
        case ping
    }

    /// Why a client's message was refused: the wire's error code (HK-229)
    /// and the error message's text.
    struct ClientMessageFailure: Error, Equatable {
        let code: String
        let message: String
    }

    /// One client text frame's payload read (HK-223 to HK-225); nil when
    /// the core fails.
    static func clientMessage(_ payload: Data) -> Result<ClientMessage, ClientMessageFailure>? {
        call("protocolClientMessage", fallback: nil) {
            switch try PowerUpCore.protocolClientMessage(payload: payload) {
            case .message(let message): return .success(ClientMessage(message))
            case .failure(let failure): return .failure(ClientMessageFailure(code: failure.code, message: failure.message))
            }
        }
    }

    /// The intent a protocol client may send by this wire name (HK-226 to
    /// HK-228); nil for a refused name, and when the core fails, so a
    /// client's intent is answered with an error and never acted on.
    static func protocolIntent(name: String, text: String?) -> Intent? {
        call("protocolIntent", fallback: nil) {
            try PowerUpCore.protocolIntent(name: name, text: text).map(Intent.init)
        }
    }

    // MARK: Server messages

    /// The session facts a `session` message carries (HK-232).
    struct SessionMessage: Equatable {
        /// The configured alias; "default" means the adapter decides.
        var model: String
        /// What the running session reports, when known.
        var liveModel: String?
        var effort: String
        var permissionMode: String
        var controlMode: String
        var sessionID: String?
        var costUSD: Double
        /// 0 (or less) when the harness reports none.
        var tokens: Int
    }

    /// A message the server sends.
    enum ServerMessage: Equatable {
        /// After a successful hello; the version is the app's.
        case welcome(appVersion: String)
        case status(AppStatus)
        case transcript(TranscriptEntry)
        case session(SessionMessage)
        case pong
        case error(code: String, message: String)
    }

    /// The text of a server message's frame: one compact line in the
    /// core's fixed member order (HK-230 to HK-234). Nil when it holds a
    /// number JSON cannot spell (a NaN or infinite cost), which is never
    /// sent, and when the core fails, which sends nothing either.
    static func protocolEncode(_ message: ServerMessage) -> String? {
        call("protocolEncode", fallback: nil) {
            try PowerUpCore.protocolEncode(message: message.core)
        }
    }

    // MARK: The handshake

    /// What a request's bytes on the listener port come to before any body.
    /// The method is uppercased and the path has lost its query.
    enum Handshake: Equatable {
        /// The header block has not ended.
        case incomplete
        /// The head has no request line.
        case unparseable
        /// Not for `/ws`: plain HTTP handling applies (HK-218).
        case notWebSocket(method: String, path: String)
        /// A refused upgrade, answered with this status (HK-219 to HK-222).
        case refuse(method: String, path: String, status: Int, reason: String)
        case accept(method: String, path: String, acceptKey: String)
    }

    /// The handshake for a request's raw bytes, bare-LF heads included
    /// (HK-254); nil when the core fails.
    static func handshake(_ request: Data) -> Handshake? {
        call("protocolHandshake", fallback: nil) {
            Handshake(try PowerUpCore.protocolHandshake(request: request))
        }
    }

    /// `Sec-WebSocket-Accept` for a client's key (HK-235); nil when the
    /// core fails.
    static func acceptKey(forClientKey key: String) -> String? {
        call("protocolAcceptKey", fallback: nil) {
            try PowerUpCore.protocolAcceptKey(clientKey: key)
        }
    }

    // MARK: Frames

    /// A frame's opcode.
    enum FrameOpcode: Equatable, CaseIterable {
        case continuation, text, binary, close, ping, pong
    }

    /// One decoded client frame, its payload unmasked.
    struct Frame: Equatable {
        let opcode: FrameOpcode
        let payload: Data
    }

    /// What decoding a buffer came to.
    enum FrameDecode: Equatable {
        /// The complete frames at the buffer's head and how many bytes they
        /// took; the rest waits for more.
        case frames([Frame], consumed: Int)
        /// A protocol violation, which refuses the whole buffer: no frame
        /// decoded before it counts.
        case violation
    }

    /// Every complete client frame at the head of `buffer` (HK-236 to
    /// HK-242); nil when the core fails, which a caller treats as a
    /// violation.
    static func decodeFrames(_ buffer: Data, maxPayload: Int) -> FrameDecode? {
        call("protocolDecodeFrames", fallback: nil) {
            FrameDecode(try PowerUpCore.protocolDecodeFrames(buffer: buffer,
                                                             maxPayload: UInt64(clamping: max(0, maxPayload))))
        }
    }

    /// One server frame, final and unmasked (HK-243); nil when the core
    /// fails.
    static func encodeFrame(opcode: FrameOpcode, payload: Data) -> Data? {
        call("protocolEncodeFrame", fallback: nil) {
            try PowerUpCore.protocolEncodeFrame(opcode: opcode.core, payload: payload)
        }
    }

    /// One server text frame; nil when the core fails.
    static func encodeText(_ payload: Data) -> Data? {
        call("protocolEncodeText", fallback: nil) {
            try PowerUpCore.protocolEncodeText(payload: payload)
        }
    }

    /// A close frame carrying `code` and no reason (HK-244); nil when the
    /// core fails.
    static func encodeClose(code: UInt16) -> Data? {
        call("protocolEncodeClose", fallback: nil) {
            try PowerUpCore.protocolEncodeClose(code: code)
        }
    }
}

// MARK: - Conversions
//
// Exhaustive switches with no `default:`, as in CoreBridge.swift.

extension CoreBridge.ClientMessage {
    fileprivate init(_ core: CoreClientMessage) {
        switch core {
        case .hello(let token): self = .hello(token: token)
        case .intent(let intent): self = .intent(Intent(intent))
        case .ping: self = .ping
        }
    }
}

extension CoreBridge.ServerMessage {
    /// Internal: the listener's broadcast and welcome send these too
    /// (CoreBridgeListener.swift).
    var core: CoreServerMessage {
        switch self {
        case .welcome(let appVersion): return .welcome(appVersion: appVersion)
        case .status(let status): return .status(status: status.core)
        case .transcript(let entry): return .transcript(entry: entry.core)
        case .session(let session):
            return .session(session: CoreSessionMessage(
                model: session.model, liveModel: session.liveModel, effort: session.effort,
                permissionMode: session.permissionMode, controlMode: session.controlMode,
                sessionId: session.sessionID, costUsd: session.costUSD, tokens: Int64(session.tokens)))
        case .pong: return .pong
        case .error(let code, let message): return .error(code: code, message: message)
        }
    }
}

extension AppStatus {
    fileprivate var core: CoreAppStatus {
        switch self {
        case .noController: return .noController
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }
}

extension CoreBridge.Handshake {
    fileprivate init(_ core: CoreHandshake) {
        switch core {
        case .incomplete: self = .incomplete
        case .unparseable: self = .unparseable
        case .notWebSocket(let method, let path): self = .notWebSocket(method: method, path: path)
        case .refuse(let method, let path, let status, let reason):
            self = .refuse(method: method, path: path, status: Int(status), reason: reason)
        case .accept(let method, let path, let acceptKey):
            self = .accept(method: method, path: path, acceptKey: acceptKey)
        }
    }
}

extension CoreBridge.FrameOpcode {
    fileprivate init(_ core: CoreFrameOpcode) {
        switch core {
        case .continuation: self = .continuation
        case .text: self = .text
        case .binary: self = .binary
        case .close: self = .close
        case .ping: self = .ping
        case .pong: self = .pong
        }
    }

    fileprivate var core: CoreFrameOpcode {
        switch self {
        case .continuation: return .continuation
        case .text: return .text
        case .binary: return .binary
        case .close: return .close
        case .ping: return .ping
        case .pong: return .pong
        }
    }
}

extension CoreBridge.FrameDecode {
    fileprivate init(_ core: CoreFrameDecode) {
        switch core {
        case .frames(let frames, let consumed):
            self = .frames(frames.map { CoreBridge.Frame(opcode: CoreBridge.FrameOpcode($0.opcode), payload: $0.payload) },
                           consumed: Int(clamping: consumed))
        case .violation: self = .violation
        }
    }
}
