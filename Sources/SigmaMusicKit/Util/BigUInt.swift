import Foundation

/// A deliberately tiny unsigned big integer: just enough for NetEase's textbook RSA
/// (a 1024-bit modulus and a 17-bit exponent). Multiplication is shift-and-add with modular
/// reduction at every step, which is slow in theory and instant for one weapi request.
struct BigUInt: Equatable, Sendable {
    /// Little-endian 32-bit limbs with no trailing zero limbs; empty means zero.
    private(set) var limbs: [UInt32]

    init(_ value: UInt32 = 0) {
        limbs = value == 0 ? [] : [value]
    }

    init(bigEndianBytes bytes: [UInt8]) {
        var limbs = [UInt32]()
        var current: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(current) }
        self.limbs = limbs
        trim()
    }

    init?(hex: String) {
        var nibbles = [UInt8]()
        for character in hex {
            guard let value = character.hexDigitValue else { return nil }
            nibbles.append(UInt8(value))
        }
        if nibbles.count % 2 == 1 { nibbles.insert(0, at: 0) }
        var bytes = [UInt8]()
        var index = 0
        while index < nibbles.count {
            bytes.append((nibbles[index] << 4) | nibbles[index + 1])
            index += 2
        }
        self.init(bigEndianBytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        var index = lhs.limbs.count - 1
        while index >= 0 {
            if lhs.limbs[index] != rhs.limbs[index] { return lhs.limbs[index] < rhs.limbs[index] }
            index -= 1
        }
        return false
    }

    private mutating func trim() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
    }

    private mutating func shiftLeftOne() {
        var carry: UInt32 = 0
        for index in 0..<limbs.count {
            let next = limbs[index] >> 31
            limbs[index] = (limbs[index] << 1) | carry
            carry = next
        }
        if carry != 0 { limbs.append(carry) }
    }

    private mutating func add(_ other: BigUInt) {
        let count = max(limbs.count, other.limbs.count)
        var result = [UInt32]()
        result.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let a = index < limbs.count ? UInt64(limbs[index]) : 0
            let b = index < other.limbs.count ? UInt64(other.limbs[index]) : 0
            let sum = a + b + carry
            result.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        limbs = result
    }

    /// Subtracts `other`, which must not be larger than `self`.
    private mutating func subtract(_ other: BigUInt) {
        var borrow: Int64 = 0
        for index in 0..<limbs.count {
            let a = Int64(limbs[index])
            let b = index < other.limbs.count ? Int64(other.limbs[index]) : 0
            var difference = a - b - borrow
            if difference < 0 {
                difference += 4_294_967_296
                borrow = 1
            } else {
                borrow = 0
            }
            limbs[index] = UInt32(difference)
        }
        trim()
    }

    /// `(a * b) mod modulus`, for `a` and `b` already below `modulus`.
    static func modMul(_ a: BigUInt, _ b: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt()
        var index = b.bitWidth - 1
        while index >= 0 {
            result.shiftLeftOne()
            if !(result < modulus) { result.subtract(modulus) }
            if b.bit(index) {
                result.add(a)
                if !(result < modulus) { result.subtract(modulus) }
            }
            index -= 1
        }
        return result
    }

    /// `self ^ exponent mod modulus`, for `self` already below `modulus`.
    func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var index = exponent.bitWidth - 1
        while index >= 0 {
            result = BigUInt.modMul(result, result, modulus: modulus)
            if exponent.bit(index) {
                result = BigUInt.modMul(result, self, modulus: modulus)
            }
            index -= 1
        }
        return result
    }

    /// Lower-case hex without leading zeros (`"0"` for zero), like Java's `BigInteger.toString(16)`.
    func hexString() -> String {
        guard let top = limbs.last else { return "0" }
        var text = String(top, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let part = String(limb, radix: 16)
            text += String(repeating: "0", count: 8 - part.count) + part
        }
        return text
    }
}
