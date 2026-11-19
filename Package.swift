// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "qr",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "qr", targets: ["qr"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        // QR Code encoder (pure Swift + Foundation) and CoreGraphics renderers.
        .target(name: "QRCore"),
        // Command-line front end.
        .executableTarget(
            name: "qr",
            dependencies: [
                "QRCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "QRCoreTests", dependencies: ["QRCore"]),
    ]
)
