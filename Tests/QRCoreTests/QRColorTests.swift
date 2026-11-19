import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import QRCore

private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> QRColor {
    QRColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: a)
}

/// Reads one pixel as straight (un-premultiplied) 8-bit RGBA.
private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
    var buffer = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setBlendMode(.copy)
    // Shift so pixel (x, y), counted from the top, lands on the 1×1 canvas.
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    let a = Int(buffer[3])
    guard a > 0 else { return [0, 0, 0, 0] }
    return buffer[0..<3].map { (Int($0) * 255 + a / 2) / a } + [a]
}

@Suite struct QRColorTests {
    @Test(arguments: [
        ("red", rgba(255, 0, 0)),
        ("RebeccaPurple", rgba(0x66, 0x33, 0x99)),
        ("transparent", QRColor.clear),
        ("clear", QRColor.clear),
        ("#f00", rgba(255, 0, 0)),
        ("#f008", rgba(255, 0, 0, 0x88 / 255)),
        ("#FF0000", rgba(255, 0, 0)),
        ("#FFFFFF00", rgba(255, 255, 255, 0)),
        ("1d3557", rgba(0x1d, 0x35, 0x57)),
        ("rgb(255, 0, 0)", rgba(255, 0, 0)),
        ("rgba(255, 255, 255, 0.0)", rgba(255, 255, 255, 0)),
        ("rgb(255 0 0 / 50%)", rgba(255, 0, 0, 0.5)),
        ("rgb(100% 0% 0%)", rgba(255, 0, 0)),
        ("rgba(0 0 255 / .25)", rgba(0, 0, 255, 0.25)),
        ("hsl(0, 100%, 50%)", rgba(255, 0, 0)),
        ("hsl(120deg 100% 25%)", rgba(0, 128, 0)),
        ("hsl(0.5turn 100% 50%)", rgba(0, 255, 255)),
        ("hsla(240, 100%, 50%, 0.5)", rgba(0, 0, 255, 0.5)),
        ("  White  ", QRColor.white),
    ])
    func parses(css: String, expected: QRColor) throws {
        let color = try #require(QRColor(css: css))
        #expect(color.rgb8 == expected.rgb8, "\(css)")
        #expect(abs(color.alpha - expected.alpha) < 0.002, "\(css)")
    }

    @Test(arguments: ["", "redd", "#12", "#12345", "rgb(1, 2)", "rgb(1 2 3 4)", "hsl(a b c)", "foo(1, 2, 3)", "rgb(1, 2, 3"])
    func rejects(css: String) {
        #expect(QRColor(css: css) == nil)
    }

    @Test func namedColorTableIsComplete() {
        // 148 CSS named colors + "transparent" + "clear".
        #expect(QRColor.named.count == 150)
    }

    @Test func contrast() {
        #expect(abs(QRColor.contrastRatio(.black, .white) - 21) < 0.01)
        #expect(QRColor.contrastRatio(.white, .white) == 1)
    }

    @Test func transparentBackgroundPNG() throws {
        let code = try QRCode(text: "Hello, world!")
        let renderer = QRRenderer(code: code, margin: 4, foreground: rgba(255, 0, 0), background: .clear)
        let image = try renderer.makeImage(pixels: 290)
        #expect(image.alphaInfo == .premultipliedLast)
        #expect(pixel(image, x: 0, y: 0)[3] == 0)                // quiet zone: transparent
        #expect(pixel(image, x: 45, y: 45) == [255, 0, 0, 255])  // top-left finder: red
    }

    @Test func opaqueFormatFlattensOntoWhite() throws {
        let code = try QRCode(text: "Hello, world!")
        let renderer = QRRenderer(code: code, foreground: .black, background: rgba(0, 0, 255, 0.5))
        let image = try renderer.makeImage(pixels: 290, transparent: false)
        #expect(image.alphaInfo == .noneSkipLast)
        let p = pixel(image, x: 0, y: 0)
        #expect(abs(p[0] - 128) <= 1 && abs(p[1] - 128) <= 1 && p[2] == 255 && p[3] == 255)
    }

    @Test func defaultColorsStayGrayscale() throws {
        let image = try QRRenderer(code: QRCode(text: "x")).makeImage(pixels: 100)
        #expect(image.colorSpace?.model == .monochrome)
    }

    @Test func coloredCodeStillScans() throws {
        let text = "Hello, world!"
        let renderer = QRRenderer(code: try QRCode(text: text), foreground: QRColor(css: "navy")!,
                                  background: QRColor(css: "lightyellow")!)
        let image = try renderer.makeImage(pixels: 300)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        let features = detector?.features(in: CIImage(cgImage: image)) as? [CIQRCodeFeature]
        #expect(features?.first?.messageString == text)
    }

    @Test func svgColors() throws {
        let renderer = QRRenderer(code: try QRCode(text: "x"), foreground: rgba(255, 0, 0, 0.5), background: .clear)
        let svg = renderer.svg(size: 100)
        #expect(svg.contains(##"<path fill="#ff0000" fill-opacity="0.5""##))
        #expect(!svg.contains("<rect"))
    }
}
