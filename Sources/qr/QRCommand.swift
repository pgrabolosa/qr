import Foundation
import QRCore

@main
struct QRCommand {
    static let usage = """
    USAGE: qr [options] [text ...]

    Generates a QR Code for TEXT. With no text (or "-"), reads from standard input;
    a single trailing newline from stdin is ignored.

    OPTIONS:
      -f, --format=FORMAT   png (default), jpeg, tiff, pdf, svg, or text
                            (inferred from --output's extension when omitted)
      -s, --size=SIZE       Image width/height, e.g. 500px (default: 512px).
                            Points for PDF; ignored for text.
      -o, --output=PATH     Output file, or "-" for stdout. Defaults to stdout,
                            or to ./qr.<ext> when stdout is a terminal and the
                            format is binary.
      -e, --ecc=LEVEL       Minimum error correction: L, M (default), Q, H.
                            Raised automatically when it doesn't grow the code.
      -m, --margin=N        Quiet zone in modules (default: 4).
      -h, --help            Show this help.

    EXAMPLES:
      qr --format=png --size=500px "https://www.apple.com/"
      echo "hello" | qr -f svg -o hello.svg
      qr -f text "WIFI:T:WPA;S:MyNetwork;P:secret;;"
    """

    struct Options {
        var format: OutputFormat?
        var size = 512
        var output: String?
        var ecc: QRCode.ErrorCorrection = .medium
        var margin = 4
        var text: [String] = []
    }

    struct UsageError: Error { let message: String }

    static func main() {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            try run(options)
        } catch let error as UsageError {
            fail("\(error.message)\nRun 'qr --help' for usage.", code: 64) // EX_USAGE
        } catch {
            fail("\(error)", code: 1)
        }
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("qr: \(message)\n".utf8))
        exit(code)
    }

    // MARK: Parsing

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        var onlyPositional = false

        while let argument = iterator.next() {
            if onlyPositional || argument == "-" || !argument.hasPrefix("-") {
                options.text.append(argument)
                continue
            }
            if argument == "--" { onlyPositional = true; continue }
            if argument == "-h" || argument == "--help" {
                print(usage)
                exit(0)
            }

            // Accept --name=value, --name value, -x value and -xvalue.
            let name: String
            var inlineValue: String?
            if argument.hasPrefix("--") {
                let parts = argument.split(separator: "=", maxSplits: 1)
                name = String(parts[0])
                inlineValue = parts.count > 1 ? String(parts[1]) : nil
            } else {
                name = String(argument.prefix(2))
                inlineValue = argument.count > 2 ? String(argument.dropFirst(2)) : nil
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard let next = iterator.next() else { throw UsageError(message: "missing value for \(name)") }
                return next
            }

            switch name {
            case "-f", "--format":
                let raw = try value()
                guard let format = OutputFormat(name: raw) else {
                    throw UsageError(message: "unknown format '\(raw)' (expected png, jpeg, tiff, pdf, svg or text)")
                }
                options.format = format
            case "-s", "--size":
                options.size = try parseSize(try value())
            case "-o", "--output":
                options.output = try value()
            case "-e", "--ecc":
                let raw = try value()
                switch raw.uppercased() {
                case "L", "LOW": options.ecc = .low
                case "M", "MEDIUM": options.ecc = .medium
                case "Q", "QUARTILE": options.ecc = .quartile
                case "H", "HIGH": options.ecc = .high
                default: throw UsageError(message: "unknown error correction level '\(raw)' (expected L, M, Q or H)")
                }
            case "-m", "--margin":
                let raw = try value()
                guard let margin = Int(raw), margin >= 0 else {
                    throw UsageError(message: "invalid margin '\(raw)'")
                }
                options.margin = margin
            default:
                throw UsageError(message: "unknown option '\(name)'")
            }
        }
        return options
    }

    static func parseSize(_ raw: String) throws -> Int {
        var number = raw.lowercased()
        for unit in ["px", "pt"] where number.hasSuffix(unit) {
            number.removeLast(unit.count)
        }
        guard let size = Int(number.trimmingCharacters(in: .whitespaces)), size > 0 else {
            throw UsageError(message: "invalid size '\(raw)' (expected e.g. 500px)")
        }
        return size
    }

    // MARK: Running

    static func run(_ options: Options) throws {
        let payload = try readPayload(options.text)
        let code = try QRCode(data: payload, errorCorrection: options.ecc)
        let renderer = QRRenderer(code: code, margin: options.margin)

        let stdoutIsTerminal = isatty(STDOUT_FILENO) != 0
        let inferredFormat = options.output.flatMap { path in
            OutputFormat(name: (path as NSString).pathExtension)
        }
        let format = options.format ?? inferredFormat ?? .png

        var destination = options.output
        if destination == nil && format.isBinary && stdoutIsTerminal {
            destination = "qr.\(format.fileExtension)"
        }

        let toTerminal = (destination == nil || destination == "-") && stdoutIsTerminal
        let data = try renderer.render(as: format, size: options.size, ansiColors: toTerminal)

        if let destination, destination != "-" {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            if options.output == nil {
                FileHandle.standardError.write(Data("Wrote \(destination)\n".utf8))
            }
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    static func readPayload(_ arguments: [String]) throws -> [UInt8] {
        if !arguments.isEmpty && arguments != ["-"] {
            return Array(arguments.joined(separator: " ").utf8)
        }
        if arguments.isEmpty && isatty(STDIN_FILENO) != 0 {
            throw UsageError(message: "no text given (pass it as an argument or pipe it on stdin)")
        }
        var bytes = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        if bytes.last == 0x0A { bytes.removeLast() }
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { throw UsageError(message: "standard input is empty") }
        return bytes
    }
}
