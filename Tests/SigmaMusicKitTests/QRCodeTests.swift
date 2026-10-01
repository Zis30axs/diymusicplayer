import Foundation
import Testing
@testable import SigmaMusicKit

#if canImport(CoreImage) && canImport(CoreGraphics) && os(macOS)
import CoreGraphics
import CoreImage

/// The encoder is checked with a real decoder (Core Image's QR detector), not against its own output.
struct QRCodeTests {
    private func image(_ code: QRCode, scale: Int = 6, quiet: Int = 4) -> CIImage {
        let side = (code.size + 2 * quiet) * scale
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)
        for y in 0..<code.size {
            for x in 0..<code.size where code.isDark(x: x, y: y) {
                // CGContext's origin is the bottom left.
                context.fill(CGRect(x: (x + quiet) * scale, y: side - (y + quiet + 1) * scale, width: scale, height: scale))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    private func decode(_ code: QRCode) -> String? {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: image(code)) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    @Test(arguments: [
        "hello",
        "https://music.163.com/login?codekey=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
        "https://music.163.com/login?codekey=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRST",
        String(repeating: "Sigma watch 0123456789. ", count: 10),
        String(repeating: "x", count: 250),
    ])
    func decodesBackToTheText(_ text: String) throws {
        let code = try QRCode(encoding: text)
        #expect(decode(code) == text, "version \(code.version)")
    }

    @Test func choosesTheSmallestVersion() throws {
        #expect(try QRCode(encoding: String(repeating: "a", count: 17)).version == 1)
        #expect(try QRCode(encoding: String(repeating: "a", count: 18)).version == 2)
        #expect(try QRCode(encoding: String(repeating: "a", count: 32)).version == 2)
        #expect(try QRCode(encoding: String(repeating: "a", count: 33)).version == 3)
        #expect(try QRCode(encoding: String(repeating: "a", count: 78)).version == 4)
        #expect(try QRCode(encoding: String(repeating: "a", count: 79)).version == 5)
    }

    @Test func rejectsWhatDoesNotFit() {
        #expect(throws: QRCode.Failure.tooLong) {
            _ = try QRCode(encoding: String(repeating: "a", count: 272))
        }
    }
}
#endif

struct QRCodeStructureTests {
    @Test func sizesGrowByFourModulesPerVersion() throws {
        #expect(try QRCode(encoding: "a").size == 21)
        #expect(try QRCode(encoding: String(repeating: "a", count: 20)).size == 25)
    }

    @Test func capacitiesMatchTheStandard() {
        // Data codewords at level L (ISO/IEC 18004 table 7).
        let expected = [19, 34, 55, 80, 108, 136, 156, 194, 232, 274]
        for (index, value) in expected.enumerated() {
            #expect(QRCode.dataCapacity(index + 1) == value, "version \(index + 1)")
        }
    }

    @Test func hasFinderPatternsAndTiming() throws {
        let code = try QRCode(encoding: "https://music.163.com/login?codekey=abc")
        for (ox, oy) in [(0, 0), (code.size - 7, 0), (0, code.size - 7)] {
            #expect(code.isDark(x: ox, y: oy))
            #expect(code.isDark(x: ox + 3, y: oy + 3))
            #expect(!code.isDark(x: ox + 1, y: oy + 1))
            #expect(code.isDark(x: ox + 6, y: oy + 6))
        }
        for i in 8..<(code.size - 8) {
            #expect(code.isDark(x: i, y: 6) == (i % 2 == 0))
            #expect(code.isDark(x: 6, y: i) == (i % 2 == 0))
        }
        #expect(code.isDark(x: 8, y: code.size - 8))  // the always-dark module
    }
}
