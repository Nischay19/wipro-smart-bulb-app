import CryptoKit
import Foundation

/// Tuya LAN command numbers used by protocol 3.5.
public enum TuyaCommand: UInt32, Sendable {
    case sessionKeyStart = 3
    case sessionKeyResponse = 4
    case sessionKeyFinish = 5
    case control = 7
    case status = 8
    case heartbeat = 9
    case controlNew = 13
    case dpQueryNew = 16

    /// Commands whose payload is sent without the "3.5" + 12×0x00 version header.
    var omitsVersionHeader: Bool {
        switch self {
        case .sessionKeyStart, .sessionKeyResponse, .sessionKeyFinish, .heartbeat, .dpQueryNew: true
        default: false
        }
    }
}

public struct TuyaFrame: Sendable, Equatable {
    public var seq: UInt32
    public var cmd: UInt32
    public var payload: [UInt8]
}

public enum TuyaError: Error, Equatable, CustomStringConvertible {
    case badPrefix(UInt32)
    case badSuffix
    case truncated
    case authenticationFailed
    case handshakeFailed(String)
    case wrongKey
    case connectionClosed
    case timeout
    case invalidKey

    public var description: String {
        switch self {
        case .badPrefix(let p): String(format: "unexpected frame prefix 0x%08X", p)
        case .badSuffix: "unexpected frame suffix"
        case .truncated: "frame is truncated"
        case .authenticationFailed: "frame failed AES-GCM authentication"
        case .handshakeFailed(let why): "session handshake failed: \(why)"
        case .wrongKey: "the bulb rejected the local key (wrong key, or the bulb was re-paired)"
        case .connectionClosed: "the bulb closed the connection"
        case .timeout: "the bulb did not answer in time"
        case .invalidKey: "local key must be 16 characters"
        }
    }
}

/// Encoder/decoder for 0x6699 (protocol 3.5) frames.
///
/// Layout: `00006699 · 0000 · seq(4) · cmd(4) · len(4) · iv(12) · ciphertext · tag(16) · 00009966`,
/// where `len` counts iv + ciphertext + tag and header bytes 4..<18 are the GCM associated data.
public enum TuyaCodec {
    static let prefix: UInt32 = 0x0000_6699
    static let suffix: UInt32 = 0x0000_9966
    public static let headerLength = 18
    static let ivLength = 12
    static let tagLength = 16
    public static let versionHeader: [UInt8] = Array("3.5".utf8) + [UInt8](repeating: 0, count: 12)

    public static func encode(cmd: UInt32, seq: UInt32, payload: [UInt8], key: SymmetricKey,
                              iv: [UInt8]? = nil) throws -> [UInt8] {
        var header = [UInt8]()
        header.appendBE(prefix)
        header.appendBE(UInt16(0))
        header.appendBE(seq)
        header.appendBE(cmd)
        header.appendBE(UInt32(ivLength + payload.count + tagLength))

        let nonceBytes = iv ?? randomBytes(ivLength)
        let sealed = try AES.GCM.seal(payload, using: key, nonce: AES.GCM.Nonce(data: nonceBytes),
                                      authenticating: header[4...])
        var out = header
        out += nonceBytes
        out += sealed.ciphertext
        out += sealed.tag
        out.appendBE(suffix)
        return out
    }

    /// Total frame size announced by a header, including header and suffix.
    public static func frameLength(header: [UInt8]) throws -> Int {
        guard header.count >= headerLength else { throw TuyaError.truncated }
        let p = header.readBE32(at: 0)
        guard p == prefix else { throw TuyaError.badPrefix(p) }
        let len = Int(header.readBE32(at: 14))
        guard len >= ivLength + tagLength, len < 0x10000 else { throw TuyaError.truncated }
        return headerLength + len + 4
    }

    /// Decodes one complete frame. The decrypted payload of device replies starts with a 4-byte
    /// return code, which is stripped (as tinytuya does for 3.5).
    public static func decode(_ frame: [UInt8], key: SymmetricKey, stripReturnCode: Bool = true) throws -> TuyaFrame {
        let total = try frameLength(header: frame)
        guard frame.count >= total else { throw TuyaError.truncated }
        guard frame.readBE32(at: total - 4) == suffix else { throw TuyaError.badSuffix }

        let bodyStart = headerLength
        let bodyEnd = total - 4
        let iv = Array(frame[bodyStart ..< bodyStart + ivLength])
        let ciphertext = Array(frame[bodyStart + ivLength ..< bodyEnd - tagLength])
        let tag = Array(frame[bodyEnd - tagLength ..< bodyEnd])

        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            plain = try AES.GCM.open(box, using: key, authenticating: frame[4 ..< headerLength])
        } catch {
            throw TuyaError.authenticationFailed
        }
        var payload = [UInt8](plain)
        if stripReturnCode, payload.count >= 4 { payload.removeFirst(4) }
        return TuyaFrame(seq: frame.readBE32(at: 6), cmd: frame.readBE32(at: 10), payload: payload)
    }

    /// Strips an optional "3.5"+12×0x00 header and returns the JSON bytes, if any.
    public static func jsonBody(_ payload: [UInt8]) -> [UInt8] {
        if payload.starts(with: versionHeader.prefix(3)), payload.count >= versionHeader.count {
            return Array(payload.dropFirst(versionHeader.count))
        }
        return payload
    }
}

// MARK: - Handshake math (kept separate so it can be unit-tested against tinytuya vectors)

public enum TuyaSession {
    public static func hmac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// session key = AES-GCM(localKey, iv = localNonce[0..<12]).encrypt(localNonce XOR remoteNonce)
    public static func sessionKey(localKey: [UInt8], localNonce: [UInt8], remoteNonce: [UInt8]) throws -> [UInt8] {
        let xor = zip(localNonce, remoteNonce).map { $0 ^ $1 }
        let sealed = try AES.GCM.seal(xor, using: SymmetricKey(data: localKey),
                                      nonce: AES.GCM.Nonce(data: Array(localNonce.prefix(12))))
        return Array(sealed.ciphertext)
    }
}

// MARK: - Byte helpers

func randomBytes(_ n: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0 ..< n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
}

extension Array where Element == UInt8 {
    mutating func appendBE(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    mutating func appendBE(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    func readBE32(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
