// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "rootshellVNC",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS("26.0"),
    ],
    products: [
        .library(name: "rootshellVNC", targets: ["rootshellVNC"]),
        .library(name: "RFBProtocol", targets: ["RFBProtocol"]),
        .library(name: "RFBTransport", targets: ["RFBTransport"]),
        .library(name: "RFBRendering", targets: ["RFBRendering"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
        // Already used and resolved by the host application. RFBTransport
        // consumes these products directly for VeNCrypt STARTTLS rather than
        // introducing a second TLS/crypto implementation.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.95.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.26.0"),
    ],
    targets: [
        // MARK: - RFBProtocol (pure types, parsing, state machine — Foundation only)
        .target(
            name: "RFBProtocol",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("z")]
        ),

        // MARK: - RFBTransport (network I/O, crypto, auth)
        .target(
            name: "RFBTransport",
            dependencies: [
                "RFBProtocol",
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - RFBRendering (VideoToolbox HEVC decode, framebuffer, display)
        .target(
            name: "RFBRendering",
            dependencies: ["RFBProtocol", "RFBRenderingC"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RFBRenderingC",
            dependencies: [],
            publicHeadersPath: "include"
        ),

        // MARK: - rootshellVNC (public API facade, SwiftUI views, input handling)
        .target(
            name: "rootshellVNC",
            dependencies: ["RFBProtocol", "RFBTransport", "RFBRendering"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(
            name: "RFBProtocolTests",
            dependencies: ["RFBProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RFBTransportTests",
            dependencies: ["RFBTransport", "RFBProtocol", .product(name: "BigInt", package: "BigInt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "rootshellVNCTests",
            dependencies: ["rootshellVNC", "RFBProtocol", "RFBTransport", "RFBRendering"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
