import Foundation

/// A QR code encoder (byte mode, error correction level L, versions 1–10), because watchOS has no Core Image
/// to draw one with. It writes the same kind of symbol the Java client's ZXing call does: the smallest version
/// that fits, the best of the eight masks. Only what login codes need is here (a URL of about 70 bytes is
/// version 4 or 5).
public struct QRCode: Sendable, Equatable {
    public enum Failure: Error, Equatable {
        case tooLong
    }

    public static let maxVersion = 10

    public let version: Int
    /// Modules per side (21 for version 1, 4 more per version).
    public let size: Int
    private let dark: [Bool]

    public func isDark(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return dark[y * size + x]
    }

    public init(encoding text: String) throws {
        try self.init(bytes: Array(text.utf8))
    }

    public init(bytes: [UInt8]) throws {
        guard let version = Self.smallestVersion(for: bytes.count) else { throw Failure.tooLong }
        let data = Self.dataCodewords(bytes, version: version)
        let codewords = Self.addErrorCorrection(data, version: version)

        var grid = Grid(version: version)
        grid.drawFunctionPatterns()
        grid.drawCodewords(codewords)

        var best = 0
        var bestPenalty = Int.max
        for mask in 0..<8 {
            grid.applyMask(mask)
            grid.drawFormatBits(mask: mask)
            let penalty = grid.penalty()
            if penalty < bestPenalty {
                bestPenalty = penalty
                best = mask
            }
            grid.applyMask(mask)  // XOR again: undo
        }
        grid.applyMask(best)
        grid.drawFormatBits(mask: best)

        self.version = version
        self.size = grid.size
        self.dark = grid.dark
    }

    // MARK: Sizes

    // Level L: error correction codewords per block and number of blocks, versions 1...10.
    private static let eccPerBlock = [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18]
    private static let blockCount = [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4]

    /// Data + error correction codewords that fit in `version`.
    static func rawCodewords(_ version: Int) -> Int {
        var modules = (16 * version + 128) * version + 64
        if version >= 2 {
            let align = version / 7 + 2
            modules -= (25 * align - 10) * align - 55
            if version >= 7 { modules -= 36 }
        }
        return modules / 8
    }

    static func dataCapacity(_ version: Int) -> Int {
        rawCodewords(version) - eccPerBlock[version] * blockCount[version]
    }

    static func smallestVersion(for byteCount: Int) -> Int? {
        for version in 1...maxVersion {
            let countBits = version < 10 ? 8 : 16
            let needed = (4 + countBits + 8 * byteCount + 7) / 8
            if needed <= dataCapacity(version) { return version }
        }
        return nil
    }

    // MARK: Data

    private static func dataCodewords(_ bytes: [UInt8], version: Int) -> [UInt8] {
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
        append(0b0100, 4)  // byte mode
        append(bytes.count, version < 10 ? 8 : 16)
        for byte in bytes { append(Int(byte), 8) }

        let capacityBits = dataCapacity(version) * 8
        append(0, min(4, capacityBits - bits.count))  // terminator
        while bits.count % 8 != 0 { bits.append(false) }

        var out = [UInt8](repeating: 0, count: bits.count / 8)
        for (i, bit) in bits.enumerated() where bit { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        var pad: UInt8 = 0xEC
        while out.count < dataCapacity(version) {
            out.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return out
    }

    /// Splits into blocks, adds Reed–Solomon codewords to each and interleaves them.
    private static func addErrorCorrection(_ data: [UInt8], version: Int) -> [UInt8] {
        let blocks = blockCount[version]
        let eccLength = eccPerBlock[version]
        let raw = rawCodewords(version)
        let shortBlocks = blocks - raw % blocks
        let shortLength = raw / blocks

        let divisor = reedSolomonDivisor(eccLength)
        var parts: [[UInt8]] = []
        var offset = 0
        for i in 0..<blocks {
            let length = shortLength - eccLength + (i < shortBlocks ? 0 : 1)
            let block = Array(data[offset..<offset + length])
            offset += length
            let ecc = reedSolomonRemainder(block, divisor)
            parts.append((i < shortBlocks ? block + [0] : block) + ecc)  // short blocks get a gap so columns line up
        }

        var result: [UInt8] = []
        for column in 0..<parts[0].count {
            for (row, part) in parts.enumerated() {
                // The gap in a short block sits after its data, before its error correction.
                if column != shortLength - eccLength || row >= shortBlocks {
                    result.append(part[column])
                }
            }
        }
        return result
    }

    private static func reedSolomonDivisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for (i, coefficient) in divisor.enumerated() {
                result[i] ^= multiply(coefficient, factor)
            }
        }
        return result
    }

    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(truncatingIfNeeded: z)
    }

    // MARK: Drawing

    private struct Grid {
        let version: Int
        let size: Int
        var dark: [Bool]
        var isFunction: [Bool]

        init(version: Int) {
            self.version = version
            size = version * 4 + 17
            dark = Array(repeating: false, count: size * size)
            isFunction = Array(repeating: false, count: size * size)
        }

        mutating func set(_ x: Int, _ y: Int, _ value: Bool) {
            dark[y * size + x] = value
            isFunction[y * size + x] = true
        }

        mutating func drawFunctionPatterns() {
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)

            let positions = alignmentPositions()
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    let corner = (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0)
                    if !corner { drawAlignment(x, y) }
                }
            }

            drawFormatBits(mask: 0)  // reserves the area; redrawn with the real mask later
            drawVersion()
        }

        private func alignmentPositions() -> [Int] {
            if version == 1 { return [] }
            let count = version / 7 + 2
            let step = (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
            var result = [6]
            var position = size - 7
            while result.count < count {
                result.insert(position, at: 1)
                position -= step
            }
            return result
        }

        private mutating func drawFinder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    let x = cx + dx
                    let y = cy + dy
                    if x >= 0, x < size, y >= 0, y < size {
                        set(x, y, distance != 2 && distance != 4)
                    }
                }
            }
        }

        private mutating func drawAlignment(_ cx: Int, _ cy: Int) {
            for dy in -2...2 {
                for dx in -2...2 {
                    set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
                }
            }
        }

        mutating func drawFormatBits(mask: Int) {
            // Level L is 01; BCH(15,5) with the generator 0x537, then masked with 0x5412.
            let data = (0b01 << 3) | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = ((data << 10) | remainder) ^ 0x5412

            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }

            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)  // always dark
        }

        private mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = (version << 12) | remainder
            for i in 0..<18 {
                let value = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3
                let b = i / 3
                set(a, b, value)
                set(b, a, value)
            }
        }

        mutating func drawCodewords(_ codewords: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = ((right + 1) & 2) == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !isFunction[y * size + x], index < codewords.count * 8 {
                            dark[y * size + x] = (codewords[index >> 3] >> (7 - (index & 7))) & 1 == 1
                            index += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y * size + x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { dark[y * size + x].toggle() }
                }
            }
        }

        /// The standard's four penalty rules: runs, 2x2 blocks, finder-like patterns, dark/light balance.
        func penalty() -> Int {
            var result = 0
            func at(_ x: Int, _ y: Int) -> Bool { dark[y * size + x] }

            for horizontal in [true, false] {
                for a in 0..<size {
                    var run = 1
                    for b in 1..<size {
                        let same = horizontal ? at(b, a) == at(b - 1, a) : at(a, b) == at(a, b - 1)
                        if same {
                            run += 1
                            if run == 5 { result += 3 } else if run > 5 { result += 1 }
                        } else {
                            run = 1
                        }
                    }
                    // finder-like 1:1:3:1:1 with four light modules on one side
                    let line = (0..<size).map { horizontal ? at($0, a) : at(a, $0) }
                    let pattern: [Bool] = [true, false, true, true, true, false, true]
                    if size >= 11 {
                        for start in 0...(size - 7) where Array(line[start..<start + 7]) == pattern {
                            let before = start >= 4 && !line[(start - 4)..<start].contains(true)
                            let after = start + 11 <= size && !line[(start + 7)..<(start + 11)].contains(true)
                            if before || after { result += 40 }
                        }
                    }
                }
            }
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let color = at(x, y)
                    if color == at(x + 1, y), color == at(x, y + 1), color == at(x + 1, y + 1) { result += 3 }
                }
            }
            let total = size * size
            let darkCount = dark.filter { $0 }.count
            let deviation = abs(darkCount * 20 - total * 10)
            result += max(0, (deviation + total - 1) / total - 1) * 10
            return result
        }
    }
}
