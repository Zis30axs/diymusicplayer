import Foundation
import Testing
@testable import SigmaMusicKit

/// Every expected value comes from running the Java original (`QQMusicDecoder.java`) on the same input.
struct QQMusicDecoderTests {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    @Test func keySchedulesMatchJava() {
        for v in QQDecoderVectors.schedules {
            let schedule = QQMusicDecoder.keySetup(Array(v.key.utf8), decrypt: v.decrypt)
            #expect(hex(schedule.flatMap { $0 }) == v.hex, "key: \(v.key) decrypt: \(v.decrypt)")
        }
    }

    @Test func desBlocksMatchJava() {
        for v in QQDecoderVectors.blocks {
            let schedule = QQMusicDecoder.keySetup(Array(v.key.utf8), decrypt: v.decrypt)
            let input = QQMusicDecoder.hexToBytes(v.input)
            let output = QQMusicDecoder.desCrypt(input, at: 0, schedule: schedule)
            #expect(hex(output) == v.output, "key: \(v.key) decrypt: \(v.decrypt) in: \(v.input)")
        }
    }

    @Test func decryptsEveryJavaCase() {
        for (index, v) in QQDecoderVectors.cases.enumerated() {
            let actual = QQMusicDecoder.decryptLyrics(v.hex)
            #expect(actual == QQDecoderVectors.plains[v.plain], "case \(index) (plain \(v.plain), level \(v.level))")
        }
    }

    @Test func decryptIgnoresWhitespaceAndCase() {
        let v = QQDecoderVectors.cases[0]
        let spaced = stride(from: 0, to: v.hex.count, by: 32).map { start -> String in
            let from = v.hex.index(v.hex.startIndex, offsetBy: start)
            let to = v.hex.index(from, offsetBy: min(32, v.hex.count - start))
            return String(v.hex[from..<to])
        }.joined(separator: "\r\n ")
        #expect(QQMusicDecoder.decryptLyrics(spaced.lowercased()) == QQDecoderVectors.plains[v.plain])
    }

    @Test func edgeCasesMatchJava() {
        for v in QQDecoderVectors.edges {
            #expect(QQMusicDecoder.decryptLyrics(v.input) == v.expected, "input: \(v.input)")
        }
        #expect(QQMusicDecoder.decryptLyrics(nil) == nil)
    }
}
