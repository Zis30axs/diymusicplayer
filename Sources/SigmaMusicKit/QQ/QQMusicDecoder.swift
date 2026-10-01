import Foundation

/// Decrypts QQ Music's QRC word-timed lyrics.
///
/// QRC arrives as hex: `hex -> Ddes(KEY1) -> des(KEY2) -> Ddes(KEY3) -> zlib inflate -> text`.
/// The DES here is **not standard**: QQMusicCommon.dll ships S-boxes with deliberate-looking bugs
/// (`sbox2` has 15 where DES has 14, `sbox4` row 4 has 10, 10 where DES has 10, 1). They must stay
/// exactly as they are, so the tables and bit permutations below are a literal port of
/// `QQMusicDecoder.java` (itself a port of wangqr/QQMusicDES `des.c`). Do not "fix" them.
///
/// Behaviour matches the Java original, including its failure modes: non-hex input is returned
/// unchanged (some songs ship plain lyrics), and anything undecryptable returns `nil`.
public enum QQMusicDecoder {
    /// Java's `\\s`: the ASCII whitespace stripped from hex input. (Not `Character`s: "\r\n" is one.)
    private static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]

    // Only the first 8 bytes of each key take part in DES.
    private static let key1 = Array("!@#)(NHL".utf8)
    private static let key2 = Array("123ZXC!@".utf8)
    private static let key3 = Array("!@#)(*$%".utf8)

    // MARK: Public API

    /// - Returns: the plaintext QRC (possibly still wrapped in XML); `encryptedHex` itself when it is
    ///   not hex; `nil` when it cannot be decrypted.
    public static func decryptLyrics(_ encryptedHex: String?) -> String? {
        guard let encryptedHex else { return nil }
        let hex = String(String.UnicodeScalarView(encryptedHex.unicodeScalars.filter { !whitespace.contains($0) }))
        if hex.isEmpty { return nil }
        if !isHex(hex) { return encryptedHex }
        if hex.utf8.count % 2 != 0 { return nil }

        var data = hexToBytes(hex)
        if data.count < 8 { return nil }

        // Triple modified DES: decrypt, encrypt, decrypt.
        desBuffer(&data, key: key1, decrypt: true)
        desBuffer(&data, key: key2, decrypt: false)
        desBuffer(&data, key: key3, decrypt: true)

        guard let inflated = Inflate.zlibInflate(data), !inflated.isEmpty else { return nil }
        return String(decoding: inflated, as: UTF8.self)
    }

    // MARK: Modified DES (literal port; see the note above)

    private static let sbox1: [UInt32] = [
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
        0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
        4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
        15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13
    ]

    private static let sbox2: [UInt32] = [
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
        3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
        0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
        13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9
    ]

    private static let sbox3: [UInt32] = [
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
        13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
        13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
        1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12
    ]

    private static let sbox4: [UInt32] = [
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
        13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
        10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
        3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14
    ]

    private static let sbox5: [UInt32] = [
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
        14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
        4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
        11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3
    ]

    private static let sbox6: [UInt32] = [
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
        10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
        9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
        4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13
    ]

    private static let sbox7: [UInt32] = [
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
        13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
        1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
        6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12
    ]

    private static let sbox8: [UInt32] = [
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
        1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
        7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
        2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11
    ]

    /// Bit `b` of the 8-byte block at `off` (MSB-first within each little-endian 32-bit word),
    /// moved to bit position `c`.
    private static func bit(_ a: [UInt8], _ off: Int, _ b: Int, _ c: Int) -> UInt32 {
        let idx = off + b / 32 * 4 + 3 - (b % 32) / 8
        return UInt32((Int(a[idx]) >> (7 - (b % 8))) & 0x01) << UInt32(c)
    }

    /// Bit `b` (counted from the MSB) of a 32-bit word, moved to bit position `c`.
    private static func bitR(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a >> UInt32(31 - b)) & 0x0000_0001) << UInt32(c)
    }

    /// Shifts `a` left by `b`, keeps the top bit and moves it down to bit position `c`.
    private static func bitL(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a << UInt32(b)) & 0x8000_0000) >> UInt32(c)
    }

    /// Re-orders a 6-bit S-box input from (first, last) row bits to the table's layout.
    private static func sboxbit(_ a: Int) -> Int {
        (a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4)
    }

    private static func ip(_ input: [UInt8], _ off: Int) -> (UInt32, UInt32) {
        var s0: UInt32 = 0
        var s1: UInt32 = 0
        s0 = bit(input, off, 57, 31) | bit(input, off, 49, 30) | bit(input, off, 41, 29) | bit(input, off, 33, 28)
        s0 |= bit(input, off, 25, 27) | bit(input, off, 17, 26) | bit(input, off, 9, 25) | bit(input, off, 1, 24)
        s0 |= bit(input, off, 59, 23) | bit(input, off, 51, 22) | bit(input, off, 43, 21) | bit(input, off, 35, 20)
        s0 |= bit(input, off, 27, 19) | bit(input, off, 19, 18) | bit(input, off, 11, 17) | bit(input, off, 3, 16)
        s0 |= bit(input, off, 61, 15) | bit(input, off, 53, 14) | bit(input, off, 45, 13) | bit(input, off, 37, 12)
        s0 |= bit(input, off, 29, 11) | bit(input, off, 21, 10) | bit(input, off, 13, 9) | bit(input, off, 5, 8)
        s0 |= bit(input, off, 63, 7) | bit(input, off, 55, 6) | bit(input, off, 47, 5) | bit(input, off, 39, 4)
        s0 |= bit(input, off, 31, 3) | bit(input, off, 23, 2) | bit(input, off, 15, 1) | bit(input, off, 7, 0)
        s1 = bit(input, off, 56, 31) | bit(input, off, 48, 30) | bit(input, off, 40, 29) | bit(input, off, 32, 28)
        s1 |= bit(input, off, 24, 27) | bit(input, off, 16, 26) | bit(input, off, 8, 25) | bit(input, off, 0, 24)
        s1 |= bit(input, off, 58, 23) | bit(input, off, 50, 22) | bit(input, off, 42, 21) | bit(input, off, 34, 20)
        s1 |= bit(input, off, 26, 19) | bit(input, off, 18, 18) | bit(input, off, 10, 17) | bit(input, off, 2, 16)
        s1 |= bit(input, off, 60, 15) | bit(input, off, 52, 14) | bit(input, off, 44, 13) | bit(input, off, 36, 12)
        s1 |= bit(input, off, 28, 11) | bit(input, off, 20, 10) | bit(input, off, 12, 9) | bit(input, off, 4, 8)
        s1 |= bit(input, off, 62, 7) | bit(input, off, 54, 6) | bit(input, off, 46, 5) | bit(input, off, 38, 4)
        s1 |= bit(input, off, 30, 3) | bit(input, off, 22, 2) | bit(input, off, 14, 1) | bit(input, off, 6, 0)
        return (s0, s1)
    }

    private static func invIp(_ s0: UInt32, _ s1: UInt32, _ out: inout [UInt8], _ off: Int) {
        var v3: UInt32 = bitR(s1, 7, 7) | bitR(s0, 7, 6) | bitR(s1, 15, 5) | bitR(s0, 15, 4)
        v3 |= bitR(s1, 23, 3) | bitR(s0, 23, 2) | bitR(s1, 31, 1) | bitR(s0, 31, 0)
        out[off + 3] = UInt8(truncatingIfNeeded: v3)
        var v2: UInt32 = bitR(s1, 6, 7) | bitR(s0, 6, 6) | bitR(s1, 14, 5) | bitR(s0, 14, 4)
        v2 |= bitR(s1, 22, 3) | bitR(s0, 22, 2) | bitR(s1, 30, 1) | bitR(s0, 30, 0)
        out[off + 2] = UInt8(truncatingIfNeeded: v2)
        var v1: UInt32 = bitR(s1, 5, 7) | bitR(s0, 5, 6) | bitR(s1, 13, 5) | bitR(s0, 13, 4)
        v1 |= bitR(s1, 21, 3) | bitR(s0, 21, 2) | bitR(s1, 29, 1) | bitR(s0, 29, 0)
        out[off + 1] = UInt8(truncatingIfNeeded: v1)
        var v0: UInt32 = bitR(s1, 4, 7) | bitR(s0, 4, 6) | bitR(s1, 12, 5) | bitR(s0, 12, 4)
        v0 |= bitR(s1, 20, 3) | bitR(s0, 20, 2) | bitR(s1, 28, 1) | bitR(s0, 28, 0)
        out[off + 0] = UInt8(truncatingIfNeeded: v0)
        var v7: UInt32 = bitR(s1, 3, 7) | bitR(s0, 3, 6) | bitR(s1, 11, 5) | bitR(s0, 11, 4)
        v7 |= bitR(s1, 19, 3) | bitR(s0, 19, 2) | bitR(s1, 27, 1) | bitR(s0, 27, 0)
        out[off + 7] = UInt8(truncatingIfNeeded: v7)
        var v6: UInt32 = bitR(s1, 2, 7) | bitR(s0, 2, 6) | bitR(s1, 10, 5) | bitR(s0, 10, 4)
        v6 |= bitR(s1, 18, 3) | bitR(s0, 18, 2) | bitR(s1, 26, 1) | bitR(s0, 26, 0)
        out[off + 6] = UInt8(truncatingIfNeeded: v6)
        var v5: UInt32 = bitR(s1, 1, 7) | bitR(s0, 1, 6) | bitR(s1, 9, 5) | bitR(s0, 9, 4)
        v5 |= bitR(s1, 17, 3) | bitR(s0, 17, 2) | bitR(s1, 25, 1) | bitR(s0, 25, 0)
        out[off + 5] = UInt8(truncatingIfNeeded: v5)
        var v4: UInt32 = bitR(s1, 0, 7) | bitR(s0, 0, 6) | bitR(s1, 8, 5) | bitR(s0, 8, 4)
        v4 |= bitR(s1, 16, 3) | bitR(s0, 16, 2) | bitR(s1, 24, 1) | bitR(s0, 24, 0)
        out[off + 4] = UInt8(truncatingIfNeeded: v4)
    }

    private static func f(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        var t1: UInt32 = bitL(state, 31, 0) | ((state & 0xf0000000) >> 1) | bitL(state, 4, 5)
        t1 |= bitL(state, 3, 6) | ((state & 0x0f000000) >> 3) | bitL(state, 8, 11)
        t1 |= bitL(state, 7, 12) | ((state & 0x00f00000) >> 5) | bitL(state, 12, 17)
        t1 |= bitL(state, 11, 18) | ((state & 0x000f0000) >> 7) | bitL(state, 16, 23)

        var t2: UInt32 = bitL(state, 15, 0) | ((state & 0x0000f000) << 15) | bitL(state, 20, 5)
        t2 |= bitL(state, 19, 6) | ((state & 0x00000f00) << 13) | bitL(state, 24, 11)
        t2 |= bitL(state, 23, 12) | ((state & 0x000000f0) << 11) | bitL(state, 28, 17)
        t2 |= bitL(state, 27, 18) | ((state & 0x0000000f) << 9) | bitL(state, 0, 23)

        let lrg0 = Int((t1 >> 24) & 0xff) ^ Int(key[0])
        let lrg1 = Int((t1 >> 16) & 0xff) ^ Int(key[1])
        let lrg2 = Int((t1 >> 8) & 0xff) ^ Int(key[2])
        let lrg3 = Int((t2 >> 24) & 0xff) ^ Int(key[3])
        let lrg4 = Int((t2 >> 16) & 0xff) ^ Int(key[4])
        let lrg5 = Int((t2 >> 8) & 0xff) ^ Int(key[5])

        var sub: UInt32 = (sbox1[sboxbit(lrg0 >> 2)] << 28) |
            (sbox2[sboxbit(((lrg0 & 0x03) << 4) | (lrg1 >> 4))] << 24)
        sub |= (sbox3[sboxbit(((lrg1 & 0x0f) << 2) | (lrg2 >> 6))] << 20) |
            (sbox4[sboxbit(lrg2 & 0x3f)] << 16)
        sub |= (sbox5[sboxbit(lrg3 >> 2)] << 12) |
            (sbox6[sboxbit(((lrg3 & 0x03) << 4) | (lrg4 >> 4))] << 8)
        sub |= (sbox7[sboxbit(((lrg4 & 0x0f) << 2) | (lrg5 >> 6))] << 4) |
            sbox8[sboxbit(lrg5 & 0x3f)]

        // P permutation (reads from `sub`)
        var permuted: UInt32 = bitL(sub, 15, 0) | bitL(sub, 6, 1) | bitL(sub, 19, 2) | bitL(sub, 20, 3)
        permuted |= bitL(sub, 28, 4) | bitL(sub, 11, 5) | bitL(sub, 27, 6) | bitL(sub, 16, 7)
        permuted |= bitL(sub, 0, 8) | bitL(sub, 14, 9) | bitL(sub, 22, 10) | bitL(sub, 25, 11)
        permuted |= bitL(sub, 4, 12) | bitL(sub, 17, 13) | bitL(sub, 30, 14) | bitL(sub, 9, 15)
        permuted |= bitL(sub, 1, 16) | bitL(sub, 7, 17) | bitL(sub, 23, 18) | bitL(sub, 13, 19)
        permuted |= bitL(sub, 31, 20) | bitL(sub, 26, 21) | bitL(sub, 2, 22) | bitL(sub, 8, 23)
        permuted |= bitL(sub, 18, 24) | bitL(sub, 12, 25) | bitL(sub, 29, 26) | bitL(sub, 5, 27)
        permuted |= bitL(sub, 21, 28) | bitL(sub, 10, 29) | bitL(sub, 3, 30) | bitL(sub, 24, 31)

        return permuted
    }

    /// The 16 six-byte round keys. `decrypt` reverses their order (Ddes).
    static func keySetup(_ key: [UInt8], decrypt: Bool) -> [[UInt8]] {
        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        let keyRndShift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
        let keyPermC = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17,
                        9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
        let keyPermD = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21,
                        13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
        let keyCompression = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9,
                              22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
                              40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47,
                              43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

        var c: UInt32 = 0
        var d: UInt32 = 0
        for i in 0..<28 {
            c |= bit(key, 0, keyPermC[i], 31 - i)
        }
        for i in 0..<28 {
            d |= bit(key, 0, keyPermD[i], 31 - i)
        }

        for i in 0..<16 {
            let s = UInt32(keyRndShift[i])
            c = ((c << s) | (c >> (28 - s))) & 0xffff_fff0
            d = ((d << s) | (d >> (28 - s))) & 0xffff_fff0

            let toGen = decrypt ? 15 - i : i
            var round = [UInt8](repeating: 0, count: 6)
            var j = 0
            while j < 24 {
                round[j / 8] |= UInt8(truncatingIfNeeded: bitR(c, keyCompression[j], 7 - (j % 8)))
                j += 1
            }
            while j < 48 {
                round[j / 8] |= UInt8(truncatingIfNeeded: bitR(d, keyCompression[j] - 27, 7 - (j % 8)))
                j += 1
            }
            schedule[toGen] = round
        }
        return schedule
    }

    /// One 8-byte DES block (16 Feistel rounds) starting at `inOff`.
    static func desCrypt(_ input: [UInt8], at inOff: Int, schedule: [[UInt8]]) -> [UInt8] {
        var (s0, s1) = ip(input, inOff)

        for idx in 0..<15 {
            let t = s1
            s1 = f(s1, schedule[idx]) ^ s0
            s0 = t
        }
        // The last round does not swap the halves.
        s0 = f(s1, schedule[15]) ^ s0

        var out = [UInt8](repeating: 0, count: 8)
        invIp(s0, s1, &out, 0)
        return out
    }

    /// DES over every whole 8-byte block of `buf`, in place; a short tail is left untouched.
    static func desBuffer(_ buf: inout [UInt8], key: [UInt8], decrypt: Bool) {
        let schedule = keySetup(key, decrypt: decrypt)
        let blocks = buf.count - (buf.count % 8)
        var offset = 0
        while offset < blocks {
            let out = desCrypt(buf, at: offset, schedule: schedule)
            for k in 0..<8 {
                buf[offset + k] = out[k]
            }
            offset += 8
        }
    }

    // MARK: Helpers

    private static func isHex(_ s: String) -> Bool {
        for byte in s.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLower = byte >= 0x61 && byte <= 0x66
            let isUpper = byte >= 0x41 && byte <= 0x46
            if !(isDigit || isLower || isUpper) { return false }
        }
        return true
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        func nibble(_ b: UInt8) -> UInt8 {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x61...0x66: return b - 0x61 + 10
            default: return b - 0x41 + 10
            }
        }
        let chars = Array(hex.utf8)
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i + 1 < chars.count {
            out.append((nibble(chars[i]) << 4) | nibble(chars[i + 1]))
            i += 2
        }
        return out
    }
}
