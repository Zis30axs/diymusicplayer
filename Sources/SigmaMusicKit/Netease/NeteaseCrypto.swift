import CommonCrypto
import CryptoKit
import Foundation

public enum NeteaseCryptoError: Error, Equatable {
    case encryptionFailed(Int)
    case invalidHex
}

/// NetEase Cloud Music's request encryption (a port of `NeteaseCrypto.java`).
///
/// - **weapi** (web player): AES-128-CBC twice, first with a fixed key and then with a random one;
///   the random key is reversed and RSA-encrypted with the web client's public key.
/// - **eapi** (desktop client): `path-36cd479b6b5-json-36cd479b6b5-md5(...)` under AES-128-ECB with
///   the client's fixed key, upper-case hex. Responses can come back encrypted the same way.
public enum NeteaseCrypto {
    public struct WeapiPayload: Sendable, Equatable {
        public let params: String
        public let encSecKey: String
    }

    private static let presetKey = Array("0CoJUm6Qyw8W8jud".utf8)
    private static let iv = Array("0102030405060708".utf8)
    private static let eapiKey = Array("e82ckenh8dichen8".utf8)
    static let eapiSeparator = "-36cd479b6b5-"
    private static let keyCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private static let publicExponent = BigUInt(65537)
    private static let modulus: BigUInt = {
        let hex = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7"
            + "b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280"
            + "104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932"
            + "575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b"
            + "3ece0462db0a22b8e7"
        guard let value = BigUInt(hex: hex) else { preconditionFailure("invalid modulus constant") }
        return value
    }()

    // MARK: weapi

    /// Encrypts a JSON body for a `/weapi/...` request. `secretKey` is random unless a test pins it.
    public static func weapi(json: String, secretKey: String? = nil) throws -> WeapiPayload {
        let key = secretKey ?? randomKey(length: 16)
        let inner = try aesCBC(text: json, key: presetKey)
        let outer = try aesCBC(text: inner, key: Array(key.utf8))
        return WeapiPayload(params: outer, encSecKey: rsa(key))
    }

    /// Base64 of AES-128-CBC/PKCS7 with NetEase's fixed IV.
    static func aesCBC(text: String, key: [UInt8]) throws -> String {
        let bytes = try crypt(
            operation: CCOperation(kCCEncrypt),
            options: CCOptions(kCCOptionPKCS7Padding),
            key: key,
            iv: iv,
            data: Array(text.utf8)
        )
        return Data(bytes).base64EncodedString()
    }

    /// The web client's textbook RSA: the reversed key as a big-endian number, no padding,
    /// left-padded to 256 hex digits.
    static func rsa(_ key: String) -> String {
        let reversed = Array(key.utf8.reversed())
        let value = BigUInt(bigEndianBytes: reversed)
        let hex = value.modPow(publicExponent, modulus: modulus).hexString()
        return String(repeating: "0", count: max(0, 256 - hex.count)) + hex
    }

    private static func randomKey(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var key = ""
        for _ in 0..<length {
            key.append(keyCharacters.randomElement(using: &generator) ?? "a")
        }
        return key
    }

    // MARK: eapi

    /// The upper-case hex `params` for an eapi request to `path` (e.g. `/api/song/lyric/v1`).
    public static func eapi(path: String, json: String) throws -> String {
        let digestInput = "nobody" + path + "use" + json + "md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let plain = path + eapiSeparator + json + eapiSeparator + digest
        let encrypted = try crypt(
            operation: CCOperation(kCCEncrypt),
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            key: eapiKey,
            iv: nil,
            data: Array(plain.utf8)
        )
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    /// Decrypts an eapi-encrypted response body (hex).
    public static func eapiDecrypt(hex: String) throws -> String {
        let bytes = try parseHex(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        let plain = try crypt(
            operation: CCOperation(kCCDecrypt),
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            key: eapiKey,
            iv: nil,
            data: bytes
        )
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: Helpers

    private static func parseHex(_ hex: String) throws -> [UInt8] {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { throw NeteaseCryptoError.invalidHex }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = characters[index].hexDigitValue,
                  let low = characters[index + 1].hexDigitValue else {
                throw NeteaseCryptoError.invalidHex
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        return bytes
    }

    private static func crypt(
        operation: CCOperation,
        options: CCOptions,
        key: [UInt8],
        iv: [UInt8]?,
        data: [UInt8]
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        // CCCrypt does not like a nil data pointer, even for zero bytes.
        let input = data.isEmpty ? [UInt8(0)] : data
        let ivBytes = iv ?? [UInt8](repeating: 0, count: kCCBlockSizeAES128)

        let status = key.withUnsafeBytes { keyPointer in
            input.withUnsafeBytes { inputPointer in
                ivBytes.withUnsafeBytes { ivPointer in
                    output.withUnsafeMutableBytes { outputPointer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPointer.baseAddress,
                            key.count,
                            ivPointer.baseAddress,
                            inputPointer.baseAddress,
                            data.count,
                            outputPointer.baseAddress,
                            capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw NeteaseCryptoError.encryptionFailed(Int(status))
        }
        output.removeLast(output.count - moved)
        return output
    }
}
