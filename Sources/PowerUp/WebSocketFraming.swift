import Foundation
import CryptoKit

/// Server-side RFC 6455 primitives for the PowerUp protocol (docs/protocol.md).
///
/// Deliberately minimal, matching the protocol's declared v0 limits: text
/// frames only at the application layer, no fragmentation (a non-final data
/// frame is a protocol violation), 1 MB payload ceiling enforced by the
/// caller. Pure functions — every byte-level behavior is unit-tested.
enum WebSocketFraming {

    /// RFC 6455 §4.2.2 handshake GUID.
    static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`.
    static func acceptKey(forClientKey key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + handshakeGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    enum Opcode: UInt8, Equatable {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    struct Frame: Equatable {
        let opcode: Opcode
        let payload: Data
    }

    enum DecodeError: Error, Equatable {
        /// Malformed, unmasked, fragmented, oversized, or unknown-opcode input.
        case protocolViolation
    }

    /// Decodes every complete frame at the head of `buffer`, removing the
    /// consumed bytes; a trailing partial frame stays for the next chunk.
    /// Client frames MUST be masked, RSV bits MUST be zero, data frames MUST
    /// be final (v0 forbids fragmentation), control frames MUST be ≤ 125
    /// bytes, and no payload may exceed `maxPayload` — anything else throws.
    static func decodeFrames(from buffer: inout Data, maxPayload: Int) throws -> [Frame] {
        let bytes = [UInt8](buffer)
        var frames: [Frame] = []
        var offset = 0

        while true {
            guard bytes.count - offset >= 2 else { break }

            let b0 = bytes[offset]
            let b1 = bytes[offset + 1]

            let fin = (b0 & 0x80) != 0
            guard (b0 & 0x70) == 0 else { throw DecodeError.protocolViolation }   // RSV bits
            guard let opcode = Opcode(rawValue: b0 & 0x0F) else { throw DecodeError.protocolViolation }

            let masked = (b1 & 0x80) != 0
            guard masked else { throw DecodeError.protocolViolation }             // client → server must mask

            let isControl = (b0 & 0x08) != 0
            if isControl {
                guard fin, (b1 & 0x7F) <= 125 else { throw DecodeError.protocolViolation }
            } else {
                guard fin, opcode != .continuation else { throw DecodeError.protocolViolation }
            }

            var headerLength = 2
            var payloadLength = Int(b1 & 0x7F)
            if payloadLength == 126 {
                guard bytes.count - offset >= 4 else { break }
                payloadLength = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                headerLength = 4
            } else if payloadLength == 127 {
                guard bytes.count - offset >= 10 else { break }
                var length: UInt64 = 0
                for i in 0..<8 {
                    length = (length << 8) | UInt64(bytes[offset + 2 + i])
                }
                guard length <= UInt64(maxPayload) else { throw DecodeError.protocolViolation }
                payloadLength = Int(length)
                headerLength = 10
            }
            guard payloadLength <= maxPayload else { throw DecodeError.protocolViolation }

            let totalLength = headerLength + 4 + payloadLength                    // + mask key
            guard bytes.count - offset >= totalLength else { break }

            let maskStart = offset + headerLength
            let payloadStart = maskStart + 4
            var payload = Data(capacity: payloadLength)
            for i in 0..<payloadLength {
                payload.append(bytes[payloadStart + i] ^ bytes[maskStart + (i % 4)])
            }

            frames.append(Frame(opcode: opcode, payload: payload))
            offset += totalLength
        }

        if offset > 0 {
            buffer.removeFirst(offset)
        }
        return frames
    }

    /// Encodes one final, unmasked frame (server → client never masks).
    static func encodeFrame(opcode: Opcode, payload: Data) -> Data {
        var data = Data()
        data.append(0x80 | opcode.rawValue)

        let length = payload.count
        if length < 126 {
            data.append(UInt8(length))
        } else if length <= 0xFFFF {
            data.append(126)
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }

        data.append(payload)
        return data
    }

    static func encodeText(_ payload: Data) -> Data {
        encodeFrame(opcode: .text, payload: payload)
    }

    static func encodeClose(code: UInt16) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        return encodeFrame(opcode: .close, payload: payload)
    }
}
