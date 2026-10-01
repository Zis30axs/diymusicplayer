import Foundation
import Testing
@testable import SigmaMusicKit

struct InflateTests {
    /// `zlib.compress(b"hello hello hello hello")` at level 6.
    private let sample: [UInt8] = [0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xB1]

    @Test func inflatesFixedHuffmanStream() {
        let out = Inflate.zlibInflate(sample)
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == "hello hello hello hello")
    }

    @Test func rejectsBadHeader() {
        #expect(Inflate.zlibInflate([0x00, 0x00, 0x00]) == nil)
    }

    @Test func rejectsChecksumMismatch() {
        var broken = sample
        broken[broken.count - 1] ^= 0xFF
        #expect(Inflate.zlibInflate(broken) == nil)
    }
}
