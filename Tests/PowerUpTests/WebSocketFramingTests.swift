import XCTest
@testable import PowerUp

/// RFC 6455 framing through the bridge (slice 2.6, DESIGN v2.15): the core
/// computes the accept key and decodes and encodes every frame.
final class WebSocketFramingTests: XCTestCase {

    // MARK: Handshake

    func testAcceptKeyMatchesRFC6455Example() {
        // The worked example from RFC 6455 §1.3.
        XCTAssertEqual(CoreBridge.acceptKey(forClientKey: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    // MARK: Round trips

    private static let opcodeBits: [CoreBridge.FrameOpcode: UInt8] = [
        .continuation: 0x0, .text: 0x1, .binary: 0x2, .close: 0x8, .ping: 0x9, .pong: 0xA,
    ]

    /// Client-style masking so server-side decode accepts our test frames.
    private func maskedFrame(opcode: CoreBridge.FrameOpcode, payload: Data,
                             mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]) -> Data {
        var data = Data()
        data.append(0x80 | (Self.opcodeBits[opcode] ?? 0))
        let length = payload.count
        if length < 126 {
            data.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            data.append(0x80 | 126)
            data.append(UInt8(length >> 8)); data.append(UInt8(length & 0xFF))
        } else {
            data.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }
        data.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            data.append(byte ^ mask[index % 4])
        }
        return data
    }

    /// The frames at the head of `input` and what is left of it; a violation
    /// fails the test.
    private func decode(_ input: Data, maxPayload: Int = 1024 * 1024) throws -> (frames: [CoreBridge.Frame], rest: Data) {
        guard case .frames(let frames, let consumed)? = CoreBridge.decodeFrames(input, maxPayload: maxPayload) else {
            XCTFail("expected frames from \(input as NSData)")
            return ([], input)
        }
        return (frames, Data(input.dropFirst(consumed)))
    }

    private func decodeAll(_ input: Data, maxPayload: Int = 1024 * 1024) throws -> [CoreBridge.Frame] {
        try decode(input, maxPayload: maxPayload).frames
    }

    private func assertViolation(_ buffer: Data, maxPayload: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CoreBridge.decodeFrames(buffer, maxPayload: maxPayload), .violation, file: file, line: line)
    }

    func testSmallTextFrameRoundTrip() throws {
        let payload = Data(#"{"type":"ping"}"#.utf8)
        let frames = try decodeAll(maskedFrame(opcode: .text, payload: payload))
        XCTAssertEqual(frames, [.init(opcode: .text, payload: payload)])
    }

    func testMediumFrameUses16BitLength() throws {
        let payload = Data(repeating: 0x61, count: 300)          // needs the 126 form
        let frames = try decodeAll(maskedFrame(opcode: .text, payload: payload))
        XCTAssertEqual(frames.first?.payload.count, 300)
    }

    func testLargeFrameUses64BitLength() throws {
        let payload = Data(repeating: 0x62, count: 70_000)       // needs the 127 form
        let frames = try decodeAll(maskedFrame(opcode: .binary, payload: payload))
        XCTAssertEqual(frames, [.init(opcode: .binary, payload: payload)])
    }

    func testMultipleFramesInOneChunkAllDecode() throws {
        var input = maskedFrame(opcode: .text, payload: Data("one".utf8))
        input.append(maskedFrame(opcode: .text, payload: Data("two".utf8)))
        let frames = try decodeAll(input)
        XCTAssertEqual(frames.map { String(decoding: $0.payload, as: UTF8.self) }, ["one", "two"])
    }

    func testPartialFrameWaitsForMoreBytes() throws {
        let whole = maskedFrame(opcode: .text, payload: Data("hello world".utf8))
        var (frames, buffer) = try decode(whole.prefix(5), maxPayload: 1024)
        XCTAssertEqual(frames, [])
        XCTAssertEqual(buffer.count, 5, "an incomplete frame must stay buffered")

        buffer.append(whole.suffix(whole.count - 5))
        (frames, buffer) = try decode(buffer, maxPayload: 1024)
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "hello world")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testServerFramesAreUnmaskedAndFinal() throws {
        let encoded = try XCTUnwrap(CoreBridge.encodeText(Data("reply".utf8)))
        XCTAssertEqual(encoded[0], 0x81)                          // FIN + text
        XCTAssertEqual(encoded[1], 5)                             // unmasked, length 5
        XCTAssertEqual(Data(encoded.suffix(5)), Data("reply".utf8))
    }

    func testEncodeCloseCarriesBigEndianCode() throws {
        let encoded = try XCTUnwrap(CoreBridge.encodeClose(code: 1002))
        XCTAssertEqual(encoded[0], 0x88)                          // FIN + close
        XCTAssertEqual(encoded[1], 2)
        XCTAssertEqual([UInt8](encoded.suffix(2)), [0x03, 0xEA]) // 1002
    }

    // MARK: Violations

    func testUnmaskedClientFrameIsRejected() throws {
        let frame = try XCTUnwrap(CoreBridge.encodeText(Data("nope".utf8)))  // server-style, no mask
        assertViolation(frame, maxPayload: 1024)
    }

    func testReservedBitsAreRejected() {
        var frame = maskedFrame(opcode: .text, payload: Data("x".utf8))
        frame[0] |= 0x40                                          // RSV1
        assertViolation(frame, maxPayload: 1024)
    }

    func testFragmentedDataFramesAreRejected() {
        var frame = maskedFrame(opcode: .text, payload: Data("x".utf8))
        frame[0] &= 0x7F                                          // clear FIN
        assertViolation(frame, maxPayload: 1024)
    }

    func testOversizedPayloadIsRejected() {
        assertViolation(maskedFrame(opcode: .text, payload: Data(repeating: 0, count: 2048)), maxPayload: 1024)
    }

    func testUnknownOpcodeIsRejected() {
        var frame = maskedFrame(opcode: .text, payload: Data())
        frame[0] = 0x83                                           // FIN + reserved opcode 0x3
        assertViolation(frame, maxPayload: 1024)
    }

    func testControlFramePayloadCapIsEnforced() {
        assertViolation(maskedFrame(opcode: .ping, payload: Data(repeating: 0, count: 200)), maxPayload: 1024 * 1024)
    }
}
