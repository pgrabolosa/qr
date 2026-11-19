import ArgumentParser
import Foundation
import QRCore

@main
struct QRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qr",
        abstract: "Generate a QR Code from text given as arguments or on standard input.",
        discussion: """
        With no text (or "-"), reads from standard input; a single trailing newline is ignored.

        Without --output, the code is written to standard output — unless that is a terminal \
        and the format is binary, in which case it is saved as ./qr.<ext>.

        EXAMPLES:
          qr --format=png --size=500px "https://www.apple.com/"
          echo "hello" | qr -f svg -o hello.svg
          qr -f text "WIFI:T:WPA;S:MyNetwork;P:secret;;"
        """
    )

    @Option(name: .shortAndLong,
            help: "Output format. Inferred from --output's extension when omitted (default: png).")
    var format: OutputFormat?

    @Option(name: .shortAndLong,
            help: "Image width and height, e.g. 500px. Points for PDF; ignored for text.")
    var size: Size = Size(512)

    @Option(name: .shortAndLong, help: ArgumentHelp("Output file, or - for standard output.", valueName: "path"))
    var output: String?

    @Option(name: .shortAndLong,
            help: "Minimum error correction level; raised automatically when it doesn't grow the code.")
    var ecc: ErrorCorrectionLevel = .M

    @Option(name: .shortAndLong, help: "Quiet zone (white border) width in modules.")
    var margin: Int = 4

    @Argument(help: "Text to encode; multiple arguments are joined with spaces.")
    var text: [String] = []

    func validate() throws {
        guard margin >= 0 else { throw ValidationError("--margin must be zero or positive.") }
    }

    func run() throws {
        let payload = try readPayload()
        let code = try QRCode(data: payload, errorCorrection: ecc.level)
        let renderer = QRRenderer(code: code, margin: margin)

        let stdoutIsTerminal = isatty(STDOUT_FILENO) != 0
        let inferredFormat = output.flatMap { OutputFormat(name: ($0 as NSString).pathExtension) }
        let format = format ?? inferredFormat ?? .png

        var destination = output
        if destination == nil && format.isBinary && stdoutIsTerminal {
            destination = "qr.\(format.fileExtension)"
        }

        let toTerminal = (destination == nil || destination == "-") && stdoutIsTerminal
        let data = try renderer.render(as: format, size: size.value, ansiColors: toTerminal)

        if let destination, destination != "-" {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            if output == nil {
                FileHandle.standardError.write(Data("Wrote \(destination)\n".utf8))
            }
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    private func readPayload() throws -> [UInt8] {
        if !text.isEmpty && text != ["-"] {
            return Array(text.joined(separator: " ").utf8)
        }
        if text.isEmpty && isatty(STDIN_FILENO) != 0 {
            throw ValidationError("No text given (pass it as an argument or pipe it on standard input).")
        }
        var bytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        if bytes.last == 0x0A { bytes.removeLast() }
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { throw ValidationError("Standard input is empty.") }
        return bytes
    }
}

// MARK: - Argument types

/// A positive pixel/point size, written as `500`, `500px` or `500pt`.
struct Size: ExpressibleByArgument {
    let value: Int

    init(_ value: Int) { self.value = value }

    init?(argument: String) {
        var number = argument.lowercased()
        for unit in ["px", "pt"] where number.hasSuffix(unit) {
            number.removeLast(unit.count)
        }
        guard let value = Int(number), value > 0 else { return nil }
        self.value = value
    }

    var defaultValueDescription: String { "\(value)px" }
}

extension OutputFormat: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
    public var defaultValueDescription: String { rawValue }
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

/// Command-line spelling of the error correction levels.
enum ErrorCorrectionLevel: String, CaseIterable, ExpressibleByArgument {
    case L, M, Q, H

    init?(argument: String) {
        switch argument.uppercased() {
        case "L", "LOW": self = .L
        case "M", "MEDIUM": self = .M
        case "Q", "QUARTILE": self = .Q
        case "H", "HIGH": self = .H
        default: return nil
        }
    }

    var level: QRCode.ErrorCorrection {
        switch self {
        case .L: .low
        case .M: .medium
        case .Q: .quartile
        case .H: .high
        }
    }

    static var allValueDescriptions: [String: String] {
        ["L": "~7% recovery", "M": "~15% recovery", "Q": "~25% recovery", "H": "~30% recovery"]
    }
}
