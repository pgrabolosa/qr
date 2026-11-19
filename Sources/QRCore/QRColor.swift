import Foundation

/// An sRGB color with straight (non-premultiplied) alpha; all components are in 0...1.
///
/// Parses a practical subset of CSS Color Level 4:
/// - hex: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` (the `#` is optional)
/// - named colors (`red`, `rebeccapurple`, …), `transparent` and its alias `clear`
/// - `rgb()`/`rgba()` with numbers (0–255) or percentages
/// - `hsl()`/`hsla()` with hue in `deg` (default), `rad`, `grad` or `turn`
///
/// Functions accept both the legacy comma syntax, `rgba(255, 0, 0, 0.5)`,
/// and the modern space syntax, `rgb(255 0 0 / 50%)`.
public struct QRColor: Equatable, Sendable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }

    /// Creates a color from a 24-bit `0xRRGGBB` value.
    public init(rgb: UInt32, alpha: Double = 1) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255,
                  green: Double(rgb >> 8 & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: alpha)
    }

    public static let black = QRColor(rgb: 0x000000)
    public static let white = QRColor(rgb: 0xFFFFFF)
    public static let clear = QRColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var isOpaque: Bool { alpha >= 1 }

    /// 8-bit components, rounded.
    public var rgb8: (red: Int, green: Int, blue: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// `#rrggbb`, ignoring alpha.
    public var hexRGB: String {
        let (r, g, b) = rgb8
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    public var description: String {
        if self == .black { return "black" }
        if self == .white { return "white" }
        if alpha == 0 { return "transparent" }
        return isOpaque ? hexRGB : hexRGB + String(format: "%02x", Int((alpha * 255).rounded()))
    }

    /// Source-over compositing of `self` onto `background`.
    public func composited(over background: QRColor) -> QRColor {
        let a = alpha + background.alpha * (1 - alpha)
        guard a > 0 else { return .clear }
        func mix(_ f: Double, _ b: Double) -> Double { (f * alpha + b * background.alpha * (1 - alpha)) / a }
        return QRColor(red: mix(red, background.red), green: mix(green, background.green),
                       blue: mix(blue, background.blue), alpha: a)
    }

    /// WCAG relative luminance, ignoring alpha.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors (1...21), ignoring alpha.
    public static func contrastRatio(_ a: QRColor, _ b: QRColor) -> Double {
        let (l1, l2) = (a.relativeLuminance, b.relativeLuminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    // MARK: - Parsing

    public init?(css: String) {
        let string = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = Self.named[string] {
            self = named
        } else if let open = string.firstIndex(of: "("), string.hasSuffix(")") {
            let function = string[..<open].trimmingCharacters(in: .whitespaces)
            let arguments = String(string[string.index(after: open)..<string.index(before: string.endIndex)])
            guard let color = Self.parseFunction(function, arguments) else { return nil }
            self = color
        } else if let color = Self.parseHex(string.hasPrefix("#") ? String(string.dropFirst()) : string) {
            self = color
        } else {
            return nil
        }
    }

    private static func parseHex(_ hex: String) -> QRColor? {
        guard [3, 4, 6, 8].contains(hex.count), let value = UInt32(hex, radix: 16) else { return nil }
        let digits = hex.count <= 4 ? 1 : 2
        let componentCount = hex.count / digits
        let max = digits == 1 ? 15.0 : 255.0
        let shift = UInt32(digits * 4)
        let mask: UInt32 = digits == 1 ? 0xF : 0xFF
        let components = (0..<componentCount).map { i in
            Double(value >> (shift * UInt32(componentCount - 1 - i)) & mask) / max
        }
        return QRColor(red: components[0], green: components[1], blue: components[2],
                       alpha: componentCount == 4 ? components[3] : 1)
    }

    private static func parseFunction(_ name: String, _ arguments: String) -> QRColor? {
        var channels: [String]
        var alphaString: String?
        if arguments.contains(",") {
            channels = arguments.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if channels.count == 4 { alphaString = channels.removeLast() }
        } else {
            let parts = arguments.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            channels = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 2 { alphaString = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard channels.count == 3 else { return nil }

        var alpha = 1.0
        if let alphaString {
            guard let value = number(alphaString, percentScale: 1) else { return nil }
            alpha = value
        }

        switch name {
        case "rgb", "rgba":
            let values = channels.compactMap { number($0, percentScale: 255) }
            guard values.count == 3 else { return nil }
            return QRColor(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: alpha)
        case "hsl", "hsla":
            guard let hue = angle(channels[0]),
                  let saturation = number(channels[1], percentScale: 100),
                  let lightness = number(channels[2], percentScale: 100)
            else { return nil }
            return hsl(hue: hue, saturation: saturation / 100, lightness: lightness / 100, alpha: alpha)
        default:
            return nil
        }
    }

    /// Parses `12.5` or `50%`; a percentage is scaled so that 100% == `percentScale`.
    private static func number(_ string: String, percentScale: Double) -> Double? {
        if string.hasSuffix("%") {
            return Double(string.dropLast()).map { $0 / 100 * percentScale }
        }
        return Double(string)
    }

    /// Parses a CSS angle and returns degrees.
    private static func angle(_ string: String) -> Double? {
        let units: [(String, Double)] = [("deg", 1), ("grad", 0.9), ("rad", 180 / .pi), ("turn", 360)]
        for (unit, factor) in units where string.hasSuffix(unit) {
            return Double(string.dropLast(unit.count)).map { $0 * factor }
        }
        return Double(string)
    }

    private static func hsl(hue: Double, saturation s: Double, lightness l: Double, alpha: Double) -> QRColor {
        let s = min(max(s, 0), 1), l = min(max(l, 0), 1)
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
        }
        return QRColor(red: f(0), green: f(8), blue: f(4), alpha: alpha)
    }

    /// CSS named colors (CSS Color Module Level 4), plus `clear`.
    static let named: [String: QRColor] = {
        let table: [String: UInt32] = [
            "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
            "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000,
            "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A,
            "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
            "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
            "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B,
            "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B,
            "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC,
            "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B,
            "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
            "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
            "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22,
            "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700,
            "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F,
            "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
            "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
            "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
            "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
            "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
            "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
            "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
            "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
            "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
            "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
            "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
            "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6,
            "olive": 0x808000, "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500,
            "orchid": 0xDA70D6, "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE,
            "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F,
            "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080,
            "rebeccapurple": 0x663399, "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1,
            "saddlebrown": 0x8B4513, "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57,
            "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB,
            "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
            "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080,
            "thistle": 0xD8BFD8, "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE,
            "wheat": 0xF5DEB3, "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00,
            "yellowgreen": 0x9ACD32,
        ]
        var colors = table.mapValues { QRColor(rgb: $0) }
        colors["transparent"] = .clear
        colors["clear"] = .clear
        return colors
    }()
}
