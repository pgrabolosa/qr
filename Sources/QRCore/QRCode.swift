import Foundation

/// A QR Code symbol (ISO/IEC 18004, Model 2, versions 1–40).
///
/// The encoder picks the most compact single-segment mode (numeric, alphanumeric or byte),
/// the smallest version that fits, and the mask pattern with the lowest penalty score.
public struct QRCode: Sendable {
    public enum ErrorCorrection: Int, CaseIterable, Comparable, Sendable {
        /// ~7% of codewords can be restored.
        case low = 0
        /// ~15% of codewords can be restored.
        case medium
        /// ~25% of codewords can be restored.
        case quartile
        /// ~30% of codewords can be restored.
        case high

        /// The 2-bit value stored in the format information.
        var formatBits: Int { [1, 0, 3, 2][rawValue] }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum EncodingError: Error, CustomStringConvertible, Equatable {
        case dataTooLong(bytes: Int, errorCorrection: ErrorCorrection)

        public var description: String {
            switch self {
            case let .dataTooLong(bytes, ecc):
                "data too long for a QR Code (\(bytes) bytes at error correction level \(ecc))"
            }
        }
    }

    /// Version number, 1...40.
    public let version: Int
    /// Width and height in modules (excluding the quiet zone).
    public let size: Int
    /// Error correction level actually used (may be higher than requested).
    public let errorCorrection: ErrorCorrection
    /// Mask pattern, 0...7.
    public let mask: Int

    private let modules: [Bool]

    /// Returns `true` for a dark module. Coordinates outside the symbol are light.
    public subscript(x: Int, y: Int) -> Bool {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return false }
        return modules[y * size + x]
    }

    /// Encodes `text` as UTF-8.
    public init(text: String, errorCorrection: ErrorCorrection = .medium, boostErrorCorrection: Bool = true) throws {
        try self.init(data: Array(text.utf8), errorCorrection: errorCorrection, boostErrorCorrection: boostErrorCorrection)
    }

    /// Encodes arbitrary bytes.
    ///
    /// - Parameters:
    ///   - errorCorrection: Minimum error correction level.
    ///   - boostErrorCorrection: Raise the level when that does not require a larger version.
    ///   - mask: Force a mask pattern (0...7) instead of choosing the best one.
    public init(data: [UInt8], errorCorrection: ErrorCorrection = .medium, boostErrorCorrection: Bool = true, mask: Int? = nil) throws {
        precondition(mask.map { (0...7).contains($0) } ?? true, "mask must be in 0...7")
        let segment = Segment(data)

        // Smallest version that fits.
        guard let version = (1...40).first(where: { v in
            segment.totalBits(version: v).map { $0 <= Self.dataCodewordCount(version: v, ecc: errorCorrection) * 8 } ?? false
        }) else {
            throw EncodingError.dataTooLong(bytes: data.count, errorCorrection: errorCorrection)
        }
        let usedBits = segment.totalBits(version: version)!

        var ecc = errorCorrection
        if boostErrorCorrection {
            for candidate in ErrorCorrection.allCases where candidate > ecc
                && usedBits <= Self.dataCodewordCount(version: version, ecc: candidate) * 8 {
                ecc = candidate
            }
        }

        // Bit stream: mode, character count, data, terminator, padding.
        let capacityBits = Self.dataCodewordCount(version: version, ecc: ecc) * 8
        var bits = BitBuffer()
        bits.append(segment.mode.indicator, count: 4)
        bits.append(segment.count, count: segment.mode.countBits(version: version))
        bits.append(contentsOf: segment.bits)
        bits.append(0, count: min(4, capacityBits - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var codewords = bits.bytes
        var pad: UInt8 = 0xEC
        while codewords.count * 8 < capacityBits {
            codewords.append(pad)
            pad ^= 0xEC ^ 0x11
        }

        var matrix = Matrix(version: version, ecc: ecc)
        matrix.drawCodewords(Self.addErrorCorrectionAndInterleave(codewords, version: version, ecc: ecc))
        let chosenMask = mask ?? matrix.bestMask()
        matrix.applyMask(chosenMask)
        matrix.drawFormatBits(mask: chosenMask)

        self.version = version
        self.size = matrix.size
        self.errorCorrection = ecc
        self.mask = chosenMask
        self.modules = matrix.modules
    }

    // MARK: - Capacity tables

    // Indexed by [ecc.rawValue][version]; index 0 is unused.
    private static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    private static let errorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    /// Number of modules available for codewords (data + ECC + remainder bits).
    static func rawDataModuleCount(version v: Int) -> Int {
        var result = (16 * v + 128) * v + 64
        if v >= 2 {
            let alignmentCount = v / 7 + 2
            result -= (25 * alignmentCount - 10) * alignmentCount - 55
            if v >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewordCount(version v: Int, ecc: ErrorCorrection) -> Int {
        rawDataModuleCount(version: v) / 8
            - eccCodewordsPerBlock[ecc.rawValue][v] * errorCorrectionBlocks[ecc.rawValue][v]
    }

    // MARK: - Reed–Solomon

    private static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int, ecc: ErrorCorrection) -> [UInt8] {
        let blockCount = errorCorrectionBlocks[ecc.rawValue][version]
        let eccLength = eccCodewordsPerBlock[ecc.rawValue][version]
        let rawCodewords = rawDataModuleCount(version: version) / 8
        let shortBlockCount = blockCount - rawCodewords % blockCount
        let shortBlockLength = rawCodewords / blockCount
        let divisor = ReedSolomon.divisor(degree: eccLength)

        var blocks: [[UInt8]] = []
        var offset = 0
        for i in 0..<blockCount {
            let length = shortBlockLength - eccLength + (i < shortBlockCount ? 0 : 1)
            var block = Array(data[offset..<offset + length])
            offset += length
            let eccBytes = ReedSolomon.remainder(block, divisor: divisor)
            if i < shortBlockCount { block.append(0) } // placeholder, skipped when interleaving
            blocks.append(block + eccBytes)
        }

        var result: [UInt8] = []
        result.reserveCapacity(rawCodewords)
        for i in 0..<blocks[0].count {
            for (j, block) in blocks.enumerated() where i != shortBlockLength - eccLength || j >= shortBlockCount {
                result.append(block[i])
            }
        }
        return result
    }
}

// MARK: - Segments

private enum Mode {
    case numeric, alphanumeric, byte

    var indicator: Int {
        switch self {
        case .numeric: 0x1
        case .alphanumeric: 0x2
        case .byte: 0x4
        }
    }

    func countBits(version: Int) -> Int {
        let index = version <= 9 ? 0 : version <= 26 ? 1 : 2
        switch self {
        case .numeric: return [10, 12, 14][index]
        case .alphanumeric: return [9, 11, 13][index]
        case .byte: return [8, 16, 16][index]
        }
    }
}

private struct Segment {
    static let alphanumericCharset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    let mode: Mode
    let count: Int
    let bits: BitBuffer

    init(_ data: [UInt8]) {
        count = data.count
        var bits = BitBuffer()
        if data.allSatisfy({ (0x30...0x39).contains($0) }) {
            mode = .numeric
            var i = 0
            while i < data.count {
                let n = min(3, data.count - i)
                let value = data[i..<i + n].reduce(0) { $0 * 10 + Int($1 - 0x30) }
                bits.append(value, count: n * 3 + 1)
                i += n
            }
        } else if data.allSatisfy({ Self.alphanumericCharset.contains($0) }) {
            mode = .alphanumeric
            let values = data.map { Self.alphanumericCharset.firstIndex(of: $0)! }
            var i = 0
            while i + 1 < values.count {
                bits.append(values[i] * 45 + values[i + 1], count: 11)
                i += 2
            }
            if i < values.count { bits.append(values[i], count: 6) }
        } else {
            mode = .byte
            for byte in data { bits.append(Int(byte), count: 8) }
        }
        self.bits = bits
    }

    /// Total bits needed at `version`, or nil if the character count does not fit its field.
    func totalBits(version: Int) -> Int? {
        let countBits = mode.countBits(version: version)
        guard count < 1 << countBits else { return nil }
        return 4 + countBits + bits.count
    }
}

private struct BitBuffer {
    private(set) var bits: [Bool] = []
    var count: Int { bits.count }

    mutating func append(_ value: Int, count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            bits.append((value >> i) & 1 != 0)
        }
    }

    mutating func append(contentsOf other: BitBuffer) { bits += other.bits }

    /// Packs bits MSB-first; `count` must be a multiple of 8.
    var bytes: [UInt8] {
        stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        }
    }
}

private enum ReedSolomon {
    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z)
    }

    static func divisor(degree: Int) -> [UInt8] {
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

    static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in result.indices { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }
}

// MARK: - Module matrix

private struct Matrix {
    let version: Int
    let size: Int
    let ecc: QRCode.ErrorCorrection
    var modules: [Bool]
    var isFunction: [Bool]

    init(version: Int, ecc: QRCode.ErrorCorrection) {
        self.version = version
        self.size = version * 4 + 17
        self.ecc = ecc
        modules = Array(repeating: false, count: size * size)
        isFunction = Array(repeating: false, count: size * size)
        drawFunctionPatterns()
    }

    subscript(x: Int, y: Int) -> Bool {
        get { modules[y * size + x] }
        set { modules[y * size + x] = newValue }
    }

    private mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y * size + x] = dark
        isFunction[y * size + x] = true
    }

    private mutating func drawFunctionPatterns() {
        // Timing patterns.
        for i in 0..<size {
            setFunction(6, i, i % 2 == 0)
            setFunction(i, 6, i % 2 == 0)
        }
        // Finder patterns (with separators).
        drawFinder(3, 3)
        drawFinder(size - 4, 3)
        drawFinder(3, size - 4)
        // Alignment patterns, except where they would overlap finders.
        let positions = alignmentPositions()
        let last = positions.count - 1
        for (i, px) in positions.enumerated() {
            for (j, py) in positions.enumerated()
            where !((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0)) {
                drawAlignment(px, py)
            }
        }
        // Reserve format areas (real bits are written after masking).
        drawFormatBits(mask: 0)
        drawVersion()
    }

    private func alignmentPositions() -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
        var result = [6]
        for i in (1..<count).reversed() {
            result.insert(size - 7 - (count - 1 - i) * step, at: 1)
        }
        return result
    }

    private mutating func drawFinder(_ x: Int, _ y: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let distance = max(abs(dx), abs(dy))
                let xx = x + dx, yy = y + dy
                if (0..<size).contains(xx), (0..<size).contains(yy) {
                    setFunction(xx, yy, distance != 2 && distance != 4)
                }
            }
        }
    }

    private mutating func drawAlignment(_ x: Int, _ y: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                setFunction(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
            }
        }
    }

    mutating func drawFormatBits(mask: Int) {
        let data = ecc.formatBits << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        let bits = (data << 10 | remainder) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 != 0 }

        // Around the top-left finder.
        for i in 0...5 { setFunction(8, i, bit(i)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }
        // Split between the other two finders.
        for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
        setFunction(8, size - 8, true) // dark module
    }

    private mutating func drawVersion() {
        guard version >= 7 else { return }
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        let bits = version << 12 | remainder
        for i in 0..<18 {
            let dark = (bits >> i) & 1 != 0
            let a = size - 11 + i % 3, b = i / 3
            setFunction(a, b, dark)
            setFunction(b, a, dark)
        }
    }

    /// Places codewords in the zig-zag order, skipping function modules.
    mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 } // skip vertical timing column
            let upward = (right + 1) & 2 == 0
            for vertical in 0..<size {
                let y = upward ? size - 1 - vertical : vertical
                for j in 0..<2 {
                    let x = right - j
                    if !isFunction[y * size + x], i < data.count * 8 {
                        self[x, y] = (data[i >> 3] >> (7 - (i & 7))) & 1 != 0
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    /// XORs the mask pattern onto non-function modules. Applying it twice undoes it.
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
                if invert { self[x, y].toggle() }
            }
        }
    }

    mutating func bestMask() -> Int {
        var best = 0
        var minPenalty = Int.max
        for mask in 0..<8 {
            applyMask(mask)
            drawFormatBits(mask: mask)
            let penalty = penaltyScore()
            if penalty < minPenalty {
                minPenalty = penalty
                best = mask
            }
            applyMask(mask) // undo
        }
        return best
    }

    /// Penalty rules N1–N4 from the specification.
    private func penaltyScore() -> Int {
        var score = 0
        let finderLike: [Bool] = [true, false, true, true, true, false, true]
        let quiet = [Bool](repeating: false, count: 4)

        func lineScore(_ line: [Bool]) -> Int {
            var s = 0
            // N1: runs of 5+ same-colour modules.
            var runLength = 1
            for i in 1...line.count {
                if i < line.count && line[i] == line[i - 1] {
                    runLength += 1
                } else {
                    if runLength >= 5 { s += 3 + runLength - 5 }
                    runLength = 1
                }
            }
            // N3: finder-like pattern with 4 light modules on either side
            // (the area outside the symbol counts as light).
            let padded = quiet + line + quiet
            for i in 0...(padded.count - 11) {
                if Array(padded[i..<i + 7]) == finderLike {
                    if padded[i + 7..<i + 11].allSatisfy({ !$0 }) { s += 40 }
                    if i >= 4 && padded[i - 4..<i].allSatisfy({ !$0 }) { s += 40 }
                }
            }
            return s
        }

        for y in 0..<size {
            score += lineScore((0..<size).map { self[$0, y] })
        }
        for x in 0..<size {
            score += lineScore((0..<size).map { self[x, $0] })
        }

        // N2: 2x2 blocks of the same colour.
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let c = self[x, y]
                if c == self[x + 1, y] && c == self[x, y + 1] && c == self[x + 1, y + 1] {
                    score += 3
                }
            }
        }

        // N4: deviation of dark proportion from 50%.
        let dark = modules.filter { $0 }.count
        let total = size * size
        let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        score += k * 10
        return score
    }
}
