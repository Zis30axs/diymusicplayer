import Foundation

/// A small, dependency-free zlib/DEFLATE decoder (RFC 1950/1951), modelled on zlib's `puff.c`.
///
/// QRC lyrics are zlib streams that may be followed by padding, and Java's `Inflater` stops at the
/// end of the stream. Apple's Compression framework decodes raw DEFLATE with no way to report where
/// the stream ended, so the decoder lives here instead. It is only used on lyric-sized inputs.
enum Inflate {
    private enum Failure: Error {
        case truncated
        case corrupt
    }

    /// Upper bound on the decoded size; lyrics are a few KB, this only stops decompression bombs.
    private static let maxOutput = 32 * 1024 * 1024

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
    ]
    private static let distBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577
    ]
    private static let distExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    ]
    private static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
    ]

    /// Inflates a zlib stream and ignores anything after it.
    ///
    /// Mirrors how the Java original uses `Inflater`: a bad header, corrupt data or a failed
    /// Adler-32 check gives `nil`; input that simply ends early gives what was decoded so far.
    static func zlibInflate(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 2 else { return [] }
        let cmf = Int(data[0])
        let flg = Int(data[1])
        guard (cmf & 0x0f) == 8, (cmf >> 4) <= 7, (cmf * 256 + flg) % 31 == 0 else { return nil }
        // A preset dictionary cannot be supplied; Java returns no output in that case.
        if flg & 0x20 != 0 { return [] }

        var reader = BitReader(data: data, position: 2)
        var output = [UInt8]()
        do {
            try inflateBlocks(&reader, &output)
        } catch Failure.truncated {
            return output
        } catch {
            return nil
        }

        // Byte-align, then verify the Adler-32 trailer if it is all there.
        reader.alignToByte()
        if reader.position + 4 <= data.count {
            let p = reader.position
            let expected = (UInt32(data[p]) << 24) | (UInt32(data[p + 1]) << 16)
                | (UInt32(data[p + 2]) << 8) | UInt32(data[p + 3])
            if adler32(output) != expected { return nil }
        }
        return output
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: Bit reader

    private struct BitReader {
        let data: [UInt8]
        var position: Int
        var bitBuffer = 0
        var bitCount = 0

        init(data: [UInt8], position: Int) {
            self.data = data
            self.position = position
        }

        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < data.count else { throw Failure.truncated }
                value |= Int(data[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> need
            bitCount -= need
            return value & ((1 << need) - 1)
        }

        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }
    }

    // MARK: Huffman tables

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
    }

    /// Builds a canonical Huffman table. `left` is > 0 for an incomplete code and < 0 for an
    /// over-subscribed one.
    private static func construct(_ lengths: [Int], count n: Int) -> (table: Huffman, left: Int) {
        var table = Huffman(symbol: [Int](repeating: 0, count: max(n, 1)))
        for symbol in 0..<n {
            table.count[lengths[symbol]] += 1
        }
        if table.count[0] == n { return (table, 0) }

        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= table.count[len]
            if left < 0 { return (table, left) }
        }

        var offsets = [Int](repeating: 0, count: 16)
        for len in 1..<15 {
            offsets[len + 1] = offsets[len] + table.count[len]
        }
        for symbol in 0..<n where lengths[symbol] != 0 {
            table.symbol[offsets[lengths[symbol]]] = symbol
            offsets[lengths[symbol]] += 1
        }
        return (table, left)
    }

    private static func decode(_ reader: inout BitReader, _ table: Huffman) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for len in 1...15 {
            code |= try reader.bits(1)
            let count = table.count[len]
            if code - count < first {
                return table.symbol[index + (code - first)]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw Failure.corrupt
    }

    // MARK: Blocks

    private static func inflateBlocks(_ reader: inout BitReader, _ output: inout [UInt8]) throws {
        var last = 0
        repeat {
            last = try reader.bits(1)
            let type = try reader.bits(2)
            switch type {
            case 0: try stored(&reader, &output)
            case 1: try fixed(&reader, &output)
            case 2: try dynamic(&reader, &output)
            default: throw Failure.corrupt
            }
        } while last == 0
    }

    private static func stored(_ reader: inout BitReader, _ output: inout [UInt8]) throws {
        reader.alignToByte()
        guard reader.position + 4 <= reader.data.count else { throw Failure.truncated }
        let p = reader.position
        let len = Int(reader.data[p]) | (Int(reader.data[p + 1]) << 8)
        let nlen = Int(reader.data[p + 2]) | (Int(reader.data[p + 3]) << 8)
        guard len == (~nlen & 0xffff) else { throw Failure.corrupt }
        reader.position += 4

        let available = reader.data.count - reader.position
        let take = min(len, available)
        output.append(contentsOf: reader.data[reader.position..<(reader.position + take)])
        reader.position += take
        if output.count > maxOutput { throw Failure.corrupt }
        if take < len { throw Failure.truncated }
    }

    private static let fixedTables: (lit: Huffman, dist: Huffman) = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        let lit = construct(lengths, count: 288).table
        let dist = construct([Int](repeating: 5, count: 30), count: 30).table
        return (lit, dist)
    }()

    private static func fixed(_ reader: inout BitReader, _ output: inout [UInt8]) throws {
        try codes(&reader, &output, fixedTables.lit, fixedTables.dist)
    }

    private static func dynamic(_ reader: inout BitReader, _ output: inout [UInt8]) throws {
        let nlen = try reader.bits(5) + 257
        let ndist = try reader.bits(5) + 1
        let ncode = try reader.bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw Failure.corrupt }

        var lengths = [Int](repeating: 0, count: 320)
        for index in 0..<ncode {
            lengths[codeLengthOrder[index]] = try reader.bits(3)
        }
        let lengthCode = construct(lengths, count: 19)
        guard lengthCode.left == 0 else { throw Failure.corrupt }

        lengths = [Int](repeating: 0, count: 320)
        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(&reader, lengthCode.table)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else {
                var previous = 0
                var repeatCount = 0
                if symbol == 16 {
                    guard index > 0 else { throw Failure.corrupt }
                    previous = lengths[index - 1]
                    repeatCount = 3 + (try reader.bits(2))
                } else if symbol == 17 {
                    repeatCount = 3 + (try reader.bits(3))
                } else {
                    repeatCount = 11 + (try reader.bits(7))
                }
                guard index + repeatCount <= nlen + ndist else { throw Failure.corrupt }
                symbol = previous
                for _ in 0..<repeatCount {
                    lengths[index] = symbol
                    index += 1
                }
            }
        }
        // The end-of-block code must exist.
        guard lengths[256] != 0 else { throw Failure.corrupt }

        let lit = construct(lengths, count: nlen)
        if lit.left != 0 && (lit.left < 0 || nlen != lit.table.count[0] + lit.table.count[1]) {
            throw Failure.corrupt
        }
        let distLengths = Array(lengths[nlen..<(nlen + ndist)])
        let dist = construct(distLengths, count: ndist)
        if dist.left != 0 && (dist.left < 0 || ndist != dist.table.count[0] + dist.table.count[1]) {
            throw Failure.corrupt
        }
        try codes(&reader, &output, lit.table, dist.table)
    }

    private static func codes(
        _ reader: inout BitReader,
        _ output: inout [UInt8],
        _ lit: Huffman,
        _ dist: Huffman
    ) throws {
        while true {
            var symbol = try decode(&reader, lit)
            if symbol < 256 {
                output.append(UInt8(symbol))
                if output.count > maxOutput { throw Failure.corrupt }
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw Failure.corrupt }
                let length = lengthBase[symbol] + (try reader.bits(lengthExtra[symbol]))
                let distSymbol = try decode(&reader, dist)
                guard distSymbol < 30 else { throw Failure.corrupt }
                let distance = distBase[distSymbol] + (try reader.bits(distExtra[distSymbol]))
                guard distance <= output.count else { throw Failure.corrupt }
                var from = output.count - distance
                for _ in 0..<length {
                    output.append(output[from])
                    from += 1
                }
                if output.count > maxOutput { throw Failure.corrupt }
            }
        }
    }
}
