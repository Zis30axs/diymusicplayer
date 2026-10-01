import Foundation
import Testing
@testable import SigmaMusicKit

/// Every expected value comes from running the Java original (`NeteaseCrypto.java`) on the same input.
struct NeteaseCryptoTests {
    @Test func aesCbcMatchesJava() throws {
        for v in CryptoVectors.cbc {
            let actual = try NeteaseCrypto.aesCBC(text: v.json, key: Array(v.key.utf8))
            #expect(actual == v.out, "json: \(v.json)")
        }
    }

    @Test func rsaMatchesJava() {
        for v in CryptoVectors.rsa {
            #expect(NeteaseCrypto.rsa(v.key) == v.out, "key: \(v.key)")
        }
    }

    @Test func weapiMatchesJava() throws {
        for v in CryptoVectors.weapi {
            let payload = try NeteaseCrypto.weapi(json: v.json, secretKey: v.key)
            #expect(payload.params == v.params, "json: \(v.json) key: \(v.key)")
            #expect(payload.encSecKey == v.encSecKey, "key: \(v.key)")
        }
    }

    @Test func weapiWithRandomKeyHasExpectedShape() throws {
        let payload = try NeteaseCrypto.weapi(json: "{\"a\":1}")
        #expect(payload.encSecKey.count == 256)
        #expect(Data(base64Encoded: payload.params) != nil)
        let second = try NeteaseCrypto.weapi(json: "{\"a\":1}")
        #expect(second.encSecKey != payload.encSecKey)
    }

    @Test func eapiMatchesJava() throws {
        for v in CryptoVectors.eapi {
            #expect(try NeteaseCrypto.eapi(path: v.path, json: v.json) == v.hex, "path: \(v.path)")
        }
    }

    @Test func eapiDecryptMatchesJava() throws {
        for v in CryptoVectors.eapiDec {
            let plain = try NeteaseCrypto.eapiDecrypt(hex: v.hex)
            #expect(plain.replacingOccurrences(of: "\n", with: "\\n") == v.plain)
        }
    }

    @Test func eapiRoundTrips() throws {
        let json = "{\"unicode\":\"日本語\"}"
        let hex = try NeteaseCrypto.eapi(path: "/api/x", json: json)
        let plain = try NeteaseCrypto.eapiDecrypt(hex: hex)
        #expect(plain.hasPrefix("/api/x-36cd479b6b5-" + json + "-36cd479b6b5-"))
    }

    @Test func eapiDecryptRejectsBadHex() {
        #expect(throws: NeteaseCryptoError.invalidHex) { try NeteaseCrypto.eapiDecrypt(hex: "ABC") }
        #expect(throws: NeteaseCryptoError.invalidHex) { try NeteaseCrypto.eapiDecrypt(hex: "ZZ") }
    }

    // MARK: BigUInt

    @Test func bigUIntModPowSmallValues() {
        let result = BigUInt(4).modPow(BigUInt(13), modulus: BigUInt(497))
        #expect(result.hexString() == "1bd")  // 4^13 mod 497 = 445
    }

    @Test func bigUIntHexRoundTrip() throws {
        let hex = "deadbeefcafebabe0123456789abcdef"
        let value = try #require(BigUInt(hex: hex))
        #expect(value.hexString() == hex)
        #expect(BigUInt(hex: "00ff")?.hexString() == "ff")
        #expect(BigUInt(hex: "xyz") == nil)
    }
}
