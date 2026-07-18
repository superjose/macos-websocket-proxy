import XCTest
@testable import ProxyCore

final class FramingTests: XCTestCase {

    func testAcceptKeyRFCVector() {
        // RFC 6455 §1.3 example.
        XCTAssertEqual(wsAcceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
                       "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testExtractKey() {
        let header = """
        GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n
        """
        XCTAssertEqual(wsExtractKey(httpHeader: header), "dGhlIHNhbXBsZSBub25jZQ==")
    }

    func testHandshakeResponseContainsAccept() {
        let resp = wsHandshakeResponse(accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 101"))
        XCTAssertTrue(resp.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    }

    func testEncodeDecodeServerUnmasked() {
        let payload = "hello".data(using: .utf8)!
        var buffer = wsEncodeFrame(opcode: .text, payload: payload) // unmasked server frame
        let frame = try! wsParseFrame(buffer: &buffer)
        XCTAssertEqual(frame?.opcode, .text)
        XCTAssertEqual(frame?.fin, true)
        XCTAssertEqual(frame?.payload, payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDecodeMaskedClientFrame() {
        let original = "{\"id\":1}".data(using: .utf8)!
        let maskKey = Data([0x12, 0x34, 0x56, 0x78])
        var buffer = wsEncodeFrame(opcode: .text, payload: original, masked: true, maskKey: maskKey)
        let parsed = try! wsParseFrame(buffer: &buffer)!
        XCTAssertEqual(parsed.opcode, .text)
        XCTAssertEqual(parsed.payload, original) // unmasking must recover the original
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLengthBoundaries() {
        for length in [0, 1, 125, 126, 65535, 65536] {
            let payload = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            var buffer = wsEncodeFrame(opcode: .binary, payload: payload)
            let frame = try! wsParseFrame(buffer: &buffer)
            XCTAssertEqual(frame?.payload, payload, "round-trip failed at length \(length)")
        }
    }

    func testIncrementalFeed() {
        let payload = "hello world".data(using: .utf8)!
        let full = wsEncodeFrame(opcode: .text, payload: payload)

        var first = Data(full.prefix(2))
        var frame = try! wsParseFrame(buffer: &first)
        XCTAssertNil(frame) // only 2 bytes: header but no payload yet

        var partial = Data(full)
        let frameComplete = try! wsParseFrame(buffer: &partial)
        XCTAssertEqual(frameComplete?.payload, payload)
    }

    func testNonZeroStartIndexBuffer() {
        // Data.removeFirst shifts startIndex: after consuming frame 1, inbound has a
        // non-zero startIndex. Parsing frame 2 must not trap on buffer[0].
        let payload = "hello".data(using: .utf8)!
        let maskKey = Data([0x11, 0x22, 0x33, 0x44])
        let frame = wsEncodeFrame(opcode: .text, payload: payload, masked: true, maskKey: maskKey)

        var inbound = Data(repeating: 0, count: 8)
        inbound.removeFirst(8) // leaves startIndex shifted, count 0
        inbound.append(frame)

        let parsed = try! wsParseFrame(buffer: &inbound)
        XCTAssertEqual(parsed?.payload, payload)
        XCTAssertTrue(inbound.isEmpty)
    }

    func testAssemblerFragments() {
        let asm = WSMessageAssembler()
        XCTAssertNil(asm.feed(WSFrame(fin: false, opcode: .text, payload: "hel".data(using: .utf8)!)))
        XCTAssertNil(asm.feed(WSFrame(fin: false, opcode: .continuation, payload: "lo ".data(using: .utf8)!)))
        let msg = asm.feed(WSFrame(fin: true, opcode: .continuation, payload: "world".data(using: .utf8)!))
        XCTAssertEqual(msg, .text("hello world"))
    }

    func testAssemblerControlInterleaved() {
        let asm = WSMessageAssembler()
        XCTAssertNil(asm.feed(WSFrame(fin: false, opcode: .text, payload: "a".data(using: .utf8)!)))
        XCTAssertEqual(asm.feed(WSFrame(fin: true, opcode: .ping, payload: Data([1]))), .ping(Data([1])))
        let msg = asm.feed(WSFrame(fin: true, opcode: .continuation, payload: "b".data(using: .utf8)!))
        XCTAssertEqual(msg, .text("ab"))
    }
}
