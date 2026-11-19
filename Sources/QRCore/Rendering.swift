import CoreGraphics
import Foundation
import ImageIO

public enum OutputFormat: String, CaseIterable, Sendable {
    case png, jpeg, tiff, pdf, svg, text

    public init?(name: String) {
        switch name.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "tif", "tiff": self = .tiff
        case "pdf": self = .pdf
        case "svg": self = .svg
        case "txt", "text", "ansi", "terminal": self = .text
        default: return nil
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        default: rawValue
        }
    }

    /// Whether the output is binary (and therefore unsuitable for a terminal).
    public var isBinary: Bool {
        switch self {
        case .png, .jpeg, .tiff, .pdf: true
        case .svg, .text: false
        }
    }

    fileprivate var imageType: CFString? {
        switch self {
        case .png: "public.png" as CFString
        case .jpeg: "public.jpeg" as CFString
        case .tiff: "public.tiff" as CFString
        default: nil
        }
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case sizeTooSmall(requested: Int, minimum: Int)
    case graphicsFailure(String)

    public var description: String {
        switch self {
        case let .sizeTooSmall(requested, minimum):
            "size \(requested)px is too small: this code needs at least \(minimum)px (1px per module)"
        case let .graphicsFailure(what):
            "graphics error: \(what)"
        }
    }
}

public struct QRRenderer: Sendable {
    public var code: QRCode
    /// Quiet zone width, in modules (the specification recommends 4).
    public var margin: Int

    public init(code: QRCode, margin: Int = 4) {
        self.code = code
        self.margin = max(0, margin)
    }

    /// Modules per side, including the quiet zone.
    public var totalModules: Int { code.size + 2 * margin }

    public func render(as format: OutputFormat, size: Int, ansiColors: Bool = false) throws -> Data {
        switch format {
        case .png, .jpeg, .tiff: try rasterData(format: format, pixels: size)
        case .pdf: try pdfData(points: size)
        case .svg: Data(svg(size: size).utf8)
        case .text: Data(text(ansiColors: ansiColors).utf8)
        }
    }

    // MARK: CoreGraphics

    /// Fills the dark modules into `context`, whose user space is `side`×`side`, origin bottom-left.
    /// With `pixelAligned`, module edges snap to whole units so a bitmap stays perfectly crisp
    /// even when `side` is not a multiple of the module count.
    public func draw(in context: CGContext, side: CGFloat, pixelAligned: Bool) {
        let total = CGFloat(totalModules)
        func edge(_ i: Int) -> CGFloat {
            let value = CGFloat(i) * side / total
            return pixelAligned ? value.rounded() : value
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(!pixelAligned)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)

        var rects: [CGRect] = []
        for y in 0..<code.size {
            var x = 0
            while x < code.size {
                guard code[x, y] else { x += 1; continue }
                // Merge horizontal runs into one rectangle.
                let start = x
                while x < code.size && code[x, y] { x += 1 }
                let x0 = edge(start + margin), x1 = edge(x + margin)
                let top = edge(y + margin), bottom = edge(y + margin + 1)
                // Flip: row 0 is at the top of the image.
                rects.append(CGRect(x: x0, y: side - bottom, width: x1 - x0, height: bottom - top))
            }
        }
        context.fill(rects)
    }

    public func makeImage(pixels: Int) throws -> CGImage {
        guard pixels >= totalModules else {
            throw RenderError.sizeTooSmall(requested: pixels, minimum: totalModules)
        }
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw RenderError.graphicsFailure("could not create bitmap context") }
        draw(in: context, side: CGFloat(pixels), pixelAligned: true)
        guard let image = context.makeImage() else {
            throw RenderError.graphicsFailure("could not create image")
        }
        return image
    }

    private func rasterData(format: OutputFormat, pixels: Int) throws -> Data {
        let image = try makeImage(pixels: pixels)
        let data = NSMutableData()
        guard let type = format.imageType,
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil)
        else { throw RenderError.graphicsFailure("\(format.rawValue) encoding is unavailable") }
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.graphicsFailure("could not encode \(format.rawValue)")
        }
        return data as Data
    }

    private func pdfData(points: Int) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: points, height: points)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw RenderError.graphicsFailure("could not create PDF context") }
        context.beginPDFPage(nil)
        draw(in: context, side: CGFloat(points), pixelAligned: false)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: Text formats

    public func svg(size: Int) -> String {
        var path = ""
        for y in 0..<code.size {
            var x = 0
            while x < code.size {
                guard code[x, y] else { x += 1; continue }
                let start = x
                while x < code.size && code[x, y] { x += 1 }
                path += "M\(start + margin) \(y + margin)h\(x - start)v1h-\(x - start)z"
            }
        }
        let n = totalModules
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(n) \(n)" shape-rendering="crispEdges">
        <rect width="\(n)" height="\(n)" fill="#fff"/>
        <path fill="#000" d="\(path)"/>
        </svg>

        """
    }

    /// Two module rows per text line using half-block characters.
    /// With `ansiColors`, forces black-on-white so it scans on dark terminal themes too.
    public func text(ansiColors: Bool) -> String {
        let (on, off) = ansiColors ? ("\u{1B}[30;107m", "\u{1B}[0m") : ("", "")
        var output = ""
        for y in stride(from: -margin, to: code.size + margin, by: 2) {
            output += on
            for x in -margin..<(code.size + margin) {
                switch (code[x, y], code[x, y + 1]) {
                case (true, true): output += "█"
                case (true, false): output += "▀"
                case (false, true): output += "▄"
                case (false, false): output += " "
                }
            }
            output += off + "\n"
        }
        return output
    }
}
