// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "qr",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "qr", targets: ["qr"]),
    ],
    targets: [
        // QR Code encoder (pure Swift + Foundation) and CoreGraphics renderers.
        .target(name: "QRCore"),
        // Command-line front end.
        .executableTarget(name: "qr", dependencies: ["QRCore"]),
        .testTarget(name: "QRCoreTests", dependencies: ["QRCore"]),
    ]
)
