import CryptoKit
import Foundation
import Testing
@testable import TuyaKit

/// Vectors generated with tinytuya 1.20.0 (the reference implementation) using a fake key and fixed
/// nonces/IVs, so the Swift port must match it byte for byte.
private let key = Array("0123456789abcdef".utf8)
private let localNonce = (0 ..< 16).map(UInt8.init)
private let remoteNonce = (16 ..< 32).map(UInt8.init)
private let sessionKeyHex = "ed2fd40d0e642b26f836170ad08ba03d"

@Test func handshakeHMACMatchesTinytuya() {
    #expect(TuyaSession.hmac(key, localNonce).hexString ==
        "b0785c289e34be92fa9f340daa07c0e0839c9bb8b2fdb1d4c119d9462e8aed4c")
}

@Test func sessionKeyMatchesTinytuya() throws {
    let sk = try TuyaSession.sessionKey(localKey: key, localNonce: localNonce, remoteNonce: remoteNonce)
    #expect(sk.hexString == sessionKeyHex)
}

@Test func controlFrameMatchesTinytuya() throws {
    let payload = TuyaCodec.versionHeader + Array(#"{"protocol":5,"t":1700000000,"data":{"dps":{"20":true}}}"#.utf8)
    let frame = try TuyaCodec.encode(cmd: 13, seq: 1, payload: payload,
                                     key: SymmetricKey(data: [UInt8](hex: sessionKeyHex)),
                                     iv: Array("0123456789ab".utf8))
    #expect(frame.hexString == "000066990000000000010000000d0000006330313233343536373839616239abae7ed7b95aca7d30f9ccbcf6975bcc4bfbe3b3f1b4d0df98d8c03875471beef214cba808d2e4e2627095ec301050f50799eeabf095d62bbb2d2986210d23b93abfd907f361e466626feea90a4d0218bcd3c667d47900009966")
}

@Test func decodesDeviceStatusPush() throws {
    let frame = [UInt8](hex: "00006699000000000007000000080000007f626139383736353433323130dd2aed2ca0b61ccd0c8630f25252fb0bf493a6861ba521498c20621387371acfd5975ad8b97f9b3126d89a1765c0998daa7165dd5f8e8ae05e2f9758f2a97668f9631d88001bd0a80974fabedfd2999dfadde5c6c1e38cc1893c767bc677689292bd4556d7dcd3611f28185ecc34d6d8053dcd00009966")
    let decoded = try TuyaCodec.decode(frame, key: SymmetricKey(data: [UInt8](hex: sessionKeyHex)))
    #expect(decoded.seq == 7)
    #expect(decoded.cmd == 8)
    let dps = try #require(TuyaConnection.parseDPS(decoded.payload))
    #expect(dps == ["21": .string("colour"), "24": .string("002f03e803e8")])

    var state = BulbState()
    state.merge(dps)
    #expect(state.mode == .colour)
    #expect(state.colour == HSV(h: 47, s: 1000, v: 1000))
}

@Test func tamperedFrameIsRejected() throws {
    var frame = try TuyaCodec.encode(cmd: 8, seq: 2, payload: [0, 0, 0, 0] + Array("{}".utf8),
                                     key: SymmetricKey(data: key))
    frame[25] ^= 0x01
    #expect(throws: TuyaError.authenticationFailed) { try TuyaCodec.decode(frame, key: SymmetricKey(data: key)) }
}

@Test func colourHexRoundTrip() {
    #expect(HSV(h: 0, s: 1000, v: 1000).hex == "000003e803e8")
    #expect(HSV(hex: "00b4012c0320") == HSV(h: 180, s: 300, v: 800))
    #expect(HSV(r: 255, g: 0, b: 0) == HSV(h: 0, s: 1000, v: 1000))
    #expect(HSV(r: 0, g: 0, b: 255).h == 240)
}

@Test func kelvinMapping() {
    #expect(Kelvin.from(temperature: 0) == 2700)
    #expect(Kelvin.from(temperature: 1000) == 6500)
    #expect(Kelvin.toTemperature(3080) == 100)
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i ..< j], radix: 16)!)
            i = j
        }
        self = bytes
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
