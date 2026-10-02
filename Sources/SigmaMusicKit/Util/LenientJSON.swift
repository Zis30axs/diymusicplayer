import Foundation

/// A forgiving JSON reader for replies `JSONDecoder` refuses.
///
/// The Java original reads every reply with Gson's lenient `JsonParser`, which accepts what strict JSON does
/// not: raw control characters (a tab or a line break) inside strings, single-quoted or unquoted names and
/// values, comments, stray or trailing commas, `=` or `;` for `:` and `,`, and a leading `)]}'`. QQ Music's
/// search and a few NetEase fields are not always clean JSON, and one such song was enough to lose a whole
/// reply here while the original read it. `JSON.parse` tries the strict decoder first and falls back to this.
///
/// Also read: a UTF-8 byte-order mark, and a JSONP wrapper (`callback({...});`). A lone surrogate escape
/// becomes U+FFFD, an unknown escape stands for the character itself.
enum LenientJSON {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> JSON {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.document()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private func fail(_ reason: String) -> Failure {
            Failure(description: "\(reason) at byte \(index)")
        }

        mutating func document() throws -> JSON {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
            skipSpace()
            if bytes[index...].starts(with: Array(")]}'".utf8)) { index += 4 }
            skipSpace()

            // `callback( ... );`
            var wrapped = false
            if let first = current, Self.isIdentifierStart(first) {
                var probe = index
                while probe < bytes.count, Self.isIdentifierPart(bytes[probe]) { probe += 1 }
                var open = probe
                while open < bytes.count, Self.isSpace(bytes[open]) { open += 1 }
                if open < bytes.count, bytes[open] == UInt8(ascii: "("), open > index {
                    index = open + 1
                    wrapped = true
                }
            }

            let value = try parseValue()
            skipSpace()
            if wrapped {
                if current == UInt8(ascii: ")") { index += 1 }
                skipSpace()
                if current == UInt8(ascii: ";") { index += 1 }
                skipSpace()
            }
            guard index >= bytes.count else { throw fail("unexpected data after the value") }
            // A bare word or number is not a reply: only objects and arrays are.
            switch value {
            case .object, .array: return value
            default: throw fail("not an object or array")
            }
        }

        private mutating func parseValue() throws -> JSON {
            skipSpace()
            guard let byte = current else { throw fail("unexpected end") }
            depth += 1
            defer { depth -= 1 }
            guard depth <= 256 else { throw fail("nested too deeply") }
            switch byte {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""), UInt8(ascii: "'"): return .string(try string())
            default: return try literal()
            }
        }

        private mutating func object() throws -> JSON {
            index += 1
            var out: [String: JSON] = [:]
            while true {
                skipSpace()
                guard let byte = current else { throw fail("unterminated object") }
                if byte == UInt8(ascii: "}") {
                    index += 1
                    return .object(out)
                }
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ";") {
                    index += 1
                    continue
                }
                let name: String
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    name = try string()
                } else {
                    name = try word()
                    guard !name.isEmpty else { throw fail("expected a name") }
                }
                skipSpace()
                if current == UInt8(ascii: ":") {
                    index += 1
                } else if current == UInt8(ascii: "=") {
                    index += 1
                    if current == UInt8(ascii: ">") { index += 1 }
                } else {
                    throw fail("expected ':'")
                }
                out[name] = try parseValue()
                skipSpace()
                switch current {
                case UInt8(ascii: ","), UInt8(ascii: ";"): index += 1
                case UInt8(ascii: "}"): break
                default: throw fail("expected ',' or '}'")
                }
            }
        }

        private mutating func array() throws -> JSON {
            index += 1
            var out: [JSON] = []
            // True at the start and after a separator: a separator met then is an empty slot, which Gson reads as null.
            var expectValue = true
            while true {
                skipSpace()
                guard let byte = current else { throw fail("unterminated array") }
                if byte == UInt8(ascii: "]") {
                    index += 1
                    return .array(out)
                }
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ";") {
                    index += 1
                    if expectValue { out.append(.null) }
                    expectValue = true
                    continue
                }
                out.append(try parseValue())
                expectValue = false
                skipSpace()
                switch current {
                case UInt8(ascii: ","), UInt8(ascii: ";"):
                    index += 1
                    expectValue = true
                case UInt8(ascii: "]"): break
                default: throw fail("expected ',' or ']'")
                }
            }
        }

        private mutating func string() throws -> String {
            let quote = bytes[index]
            index += 1
            var out: [UInt8] = []
            while true {
                guard let byte = current else { throw fail("unterminated string") }
                index += 1
                if byte == quote { return String(decoding: out, as: UTF8.self) }
                guard byte == UInt8(ascii: "\\") else {
                    out.append(byte)  // raw control characters included
                    continue
                }
                guard let escape = current else { throw fail("unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"): out.append(contentsOf: try unicodeEscape())
                default: out.append(escape)  // \" \' \\ \/ and anything unknown
                }
            }
        }

        private mutating func unicodeEscape() throws -> [UInt8] {
            let unit = try hex4()
            var scalar: UInt32 = unit
            if (0xD800..<0xDC00).contains(unit) {
                // A high surrogate wants its low half right behind it.
                if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try hex4()
                    if (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                        scalar = 0xFFFD
                    }
                } else {
                    scalar = 0xFFFD
                }
            } else if (0xDC00..<0xE000).contains(unit) {
                scalar = 0xFFFD
            }
            return Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8)
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail("short \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Self.hexValue(bytes[index]) else { throw fail("bad \\u escape") }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        /// An unquoted token: up to a delimiter.
        private mutating func word() throws -> String {
            let start = index
            while let byte = current, !Self.isDelimiter(byte) { index += 1 }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        private mutating func literal() throws -> JSON {
            let text = try word()
            guard !text.isEmpty else { throw fail("unexpected character") }
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let whole = Int64(text) { return .int(whole) }
            if let fraction = Double(text), fraction.isFinite { return .double(fraction) }
            return .string(text)
        }

        private mutating func skipSpace() {
            while let byte = current {
                if Self.isSpace(byte) {
                    index += 1
                } else if byte == UInt8(ascii: "#") {
                    skipLine()
                } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count {
                    if bytes[index + 1] == UInt8(ascii: "/") {
                        skipLine()
                    } else if bytes[index + 1] == UInt8(ascii: "*") {
                        index += 2
                        while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                            index += 1
                        }
                        index = min(bytes.count, index + 2)
                    } else {
                        return
                    }
                } else {
                    return
                }
            }
        }

        private mutating func skipLine() {
            while let byte = current, byte != 0x0A, byte != 0x0D { index += 1 }
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
        }

        private static func isDelimiter(_ byte: UInt8) -> Bool {
            if isSpace(byte) { return true }
            switch byte {
            case UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "/"),
                 UInt8(ascii: "\\"), UInt8(ascii: "#"), UInt8(ascii: "="), UInt8(ascii: "\""), UInt8(ascii: "'"):
                return true
            default:
                return false
            }
        }

        private static func isIdentifierStart(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
        }

        private static func isIdentifierPart(_ byte: UInt8) -> Bool {
            isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: ".")
        }

        private static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: return UInt32(byte - 0x30)
            case 0x41...0x46: return UInt32(byte - 0x41 + 10)
            case 0x61...0x66: return UInt32(byte - 0x61 + 10)
            default: return nil
            }
        }
    }
}
