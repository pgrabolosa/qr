import CoreGraphics
import CoreImage
import Testing
@testable import QRCore

/// Decodes with Apple's built-in detector (test-only dependency) to verify round trips.
private func decode(_ code: QRCode) throws -> String? {
    let renderer = QRRenderer(code: code, margin: 4)
    let image = try renderer.makeImage(pixels: renderer.totalModules * 6)
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cgImage: image)) as? [CIQRCodeFeature]
    return features?.first?.messageString
}

@Suite struct QRCodeTests {
    @Test func capacityTables() {
        // Spot-check against ISO/IEC 18004 Table 7 (data codewords).
        #expect(QRCode.dataCodewordCount(version: 1, ecc: .low) == 19)
        #expect(QRCode.dataCodewordCount(version: 1, ecc: .high) == 9)
        #expect(QRCode.dataCodewordCount(version: 10, ecc: .medium) == 216)
        #expect(QRCode.dataCodewordCount(version: 40, ecc: .low) == 2956)
        #expect(QRCode.dataCodewordCount(version: 40, ecc: .high) == 1276)
    }

    @Test func modeSelection() throws {
        // Max lengths for version 1-L: 41 numeric, 25 alphanumeric, 17 bytes.
        #expect(try QRCode(text: String(repeating: "7", count: 41), errorCorrection: .low, boostErrorCorrection: false).version == 1)
        #expect(try QRCode(text: String(repeating: "A", count: 25), errorCorrection: .low, boostErrorCorrection: false).version == 1)
        #expect(try QRCode(text: String(repeating: "a", count: 17), errorCorrection: .low, boostErrorCorrection: false).version == 1)
        #expect(try QRCode(text: String(repeating: "a", count: 18), errorCorrection: .low, boostErrorCorrection: false).version == 2)
    }

    @Test func tooLong() {
        #expect(throws: QRCode.EncodingError.self) {
            try QRCode(data: Array(repeating: 0x61, count: 2954), errorCorrection: .low)
        }
    }

    @Test(arguments: QRCode.ErrorCorrection.allCases)
    func roundTripAcrossVersions(ecc: QRCode.ErrorCorrection) throws {
        var seen = Set<Int>()
        for length in [1, 10, 30, 60, 100, 150, 250, 400, 600, 900] {
            let text = String((0..<length).map { i in Array("https://example.com/Ünïcødé?q=")[i % 30] })
            guard let code = try? QRCode(text: text, errorCorrection: ecc, boostErrorCorrection: false) else { continue }
            seen.insert(code.version)
            #expect(try decode(code) == text, "version \(code.version), ecc \(ecc)")
        }
        #expect(seen.count >= 6)
    }

    @Test(arguments: 0..<8)
    func everyMaskDecodes(mask: Int) throws {
        let text = "https://www.apple.com/"
        let code = try QRCode(data: Array(text.utf8), mask: mask)
        #expect(code.mask == mask)
        #expect(try decode(code) == text)
    }

    @Test func numericAndAlphanumericDecode() throws {
        for text in ["0123456789012345678901234567890", "HELLO WORLD $%*+-./:"] {
            #expect(try decode(QRCode(text: text)) == text)
        }
    }

    @Test func nonMultipleSizeIsCrisp() throws {
        let renderer = QRRenderer(code: try QRCode(text: "https://www.apple.com/"))
        let image = try renderer.makeImage(pixels: 500)
        #expect(image.width == 500 && image.height == 500)
        #expect(throws: RenderError.self) { try renderer.makeImage(pixels: 10) }
    }
}
