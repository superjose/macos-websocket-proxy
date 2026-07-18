import Foundation
import CryptoKit

/// RFC 6455 §1.3 magic GUID appended to the client's Sec-WebSocket-Key.
let WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

enum WSOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WSFrame {
    let fin: Bool
    let opcode: WSOpcode
    let payload: Data
}

/// A fully-assembled WebSocket message (data or control).
enum WSMessage: Equatable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close
}

enum WSFramingError: Error {
    case invalidOpcode
    case rsvNotZero
    case controlFragmented
    case controlTooLong
}

/// Compute the Sec-WebSocket-Accept value for a given Sec-WebSocket-Key (RFC 6455 §1.3).
func wsAcceptKey(for key: String) -> String {
    let combined = key + WS_GUID
    let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
    return Data(digest).base64EncodedString()
}

/// Encode one frame. Servers send unmasked frames; clients must mask.
func wsEncodeFrame(fin: Bool = true, opcode: WSOpcode, payload: Data, masked: Bool = false, maskKey: Data? = nil) -> Data {
    var frame = Data()

    var byte0: UInt8 = opcode.rawValue & 0x0F
    if fin { byte0 |= 0x80 }
    frame.append(byte0)

    var byte1: UInt8 = 0
    var key: Data? = nil
    if masked {
        byte1 |= 0x80
        // ponytail: random mask; clients must mask, server never sends masked.
        key = maskKey ?? Data((0..<4).map { _ in UInt8.random(in: 0...255) })
    }

    let len = payload.count
    if len <= 125 {
        byte1 |= UInt8(len)
        frame.append(byte1)
    } else if len <= 0xFFFF {
        byte1 |= 126
        frame.append(byte1)
        var l = UInt16(len).bigEndian
        withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
    } else {
        byte1 |= 127
        frame.append(byte1)
        var l = UInt64(len).bigEndian
        withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
    }

    if let key {
        frame.append(key)
        var maskedPayload = Data(payload)
        for i in 0..<maskedPayload.count {
            maskedPayload[i] ^= key[i % 4]
        }
        frame.append(maskedPayload)
    } else {
        frame.append(payload)
    }
    return frame
}

/// Try to parse one frame from the front of `buffer`. On success, consumes those bytes
/// (via `removeFirst`) and returns the frame. Returns nil if not enough bytes yet.
/// Indexing is startIndex-relative: `removeFirst` shifts a Data's startIndex, so after
/// consuming one frame the buffer is no longer 0-based.
func wsParseFrame(buffer: inout Data) throws -> WSFrame? {
    guard buffer.count >= 2 else { return nil }

    let base = buffer.startIndex
    let byte0 = buffer[base]
    let byte1 = buffer[base + 1]

    let fin = (byte0 & 0x80) != 0
    guard (byte0 & 0x70) == 0 else { throw WSFramingError.rsvNotZero }
    guard let opcode = WSOpcode(rawValue: byte0 & 0x0F) else { throw WSFramingError.invalidOpcode }

    let masked = (byte1 & 0x80) != 0
    let len7 = Int(byte1 & 0x7F)

    var idx = 2
    var length = 0

    if len7 < 126 {
        length = len7
    } else if len7 == 126 {
        guard buffer.count >= idx + 2 else { return nil }
        length = (Int(buffer[base + idx]) << 8) | Int(buffer[base + idx + 1])
        idx += 2
    } else { // 127
        guard buffer.count >= idx + 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(buffer[base + idx + i])
        }
        length = Int(v) // ponytail: no cap; a local proxy won't see >Int.max payloads
        idx += 8
    }

    var maskKey: Data? = nil
    if masked {
        guard buffer.count >= idx + 4 else { return nil }
        maskKey = Data(buffer[(base + idx)..<(base + idx + 4)])
        idx += 4
    }

    guard buffer.count >= idx + length else { return nil }

    var payload = Data(buffer[(base + idx)..<(base + idx + length)])
    if let maskKey {
        for i in 0..<payload.count {
            payload[payload.startIndex + i] ^= maskKey[maskKey.startIndex + (i % 4)]
        }
    }

    buffer.removeFirst(idx + length)

    if opcode == .close || opcode == .ping || opcode == .pong {
        if length > 125 { throw WSFramingError.controlTooLong }
        if !fin { throw WSFramingError.controlFragmented }
    }

    return WSFrame(fin: fin, opcode: opcode, payload: payload)
}

/// Accumulates fragmented data frames into a single message, passing control frames through.
final class WSMessageAssembler {
    private var fragments = Data()
    private var messageOpcode: WSOpcode?

    /// Feed a parsed frame; returns a complete message when a data message finishes
    /// (or immediately for control frames), otherwise nil.
    func feed(_ frame: WSFrame) -> WSMessage? {
        switch frame.opcode {
        case .text, .binary:
            fragments.removeAll(keepingCapacity: true)
            messageOpcode = frame.opcode
            if frame.fin {
                let msg = makeMessage(opcode: frame.opcode, data: frame.payload)
                messageOpcode = nil
                return msg
            }
            fragments.append(frame.payload)
            return nil

        case .continuation:
            fragments.append(frame.payload)
            guard frame.fin else { return nil }
            guard let op = messageOpcode else { return nil }
            let msg = makeMessage(opcode: op, data: fragments)
            fragments.removeAll(keepingCapacity: true)
            messageOpcode = nil
            return msg

        case .close:  return .close
        case .ping:   return .ping(frame.payload)
        case .pong:   return .pong(frame.payload)
        }
    }

    private func makeMessage(opcode: WSOpcode, data: Data) -> WSMessage {
        switch opcode {
        case .text: return .text(String(data: data, encoding: .utf8) ?? "")
        default:    return .binary(data)
        }
    }
}

// MARK: - HTTP handshake helpers

/// Extract Sec-WebSocket-Key from a raw HTTP request header block (case-insensitive).
func wsExtractKey(httpHeader: String) -> String? {
    for line in httpHeader.components(separatedBy: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sec-websocket-key" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
    }
    return nil
}

func wsHandshakeResponse(accept: String) -> String {
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
}

func wsBadResponse(_ status: Int, _ reason: String) -> String {
    "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
}
