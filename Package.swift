// swift-tools-version: 6.0

import Foundation
import PackageDescription

// A gitignored `.optimize-debug` marker next to this manifest builds Debug with
// release optimization for a local checkout. Remote checkouts never have it,
// which matters because SwiftPM rejects version-pinned dependencies that use
// unsafe flags. The switch is deliberately a file in the checkout rather than
// an environment variable: a variable set for a host build would also reach
// this manifest in a pinned checkout and get the package rejected.
//
// The marker is read when this manifest is evaluated, and SwiftPM and Xcode
// cache that evaluation by this file's contents, not by the marker. Creating
// or removing the marker therefore has no effect until the cached evaluation
// is discarded: delete ~/Library/Caches/org.swift.swiftpm/manifests and, for
// Xcode or xcodebuild, the project's DerivedData as well. `swift build
// --manifest-cache none` reads the marker afresh, but only for that one
// invocation; the next ordinary build goes back to the cached evaluation.
let optimizeDebug = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/.optimize-debug"
)
let debugSwiftOptimization: [SwiftSetting] = optimizeDebug
    ? [.unsafeFlags(["-O"], .when(configuration: .debug))] : []
let debugCOptimization: [CSetting] = optimizeDebug
    ? [.unsafeFlags(["-Os"], .when(configuration: .debug))] : []

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
            swiftSettings: [.swiftLanguageMode(.v6)] + debugSwiftOptimization,
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
            swiftSettings: [.swiftLanguageMode(.v6)] + debugSwiftOptimization
        ),

        // MARK: - RFBRendering (VideoToolbox HEVC decode, framebuffer, display)
        .target(
            name: "RFBRendering",
            dependencies: ["RFBProtocol", "RFBRenderingC"],
            swiftSettings: [.swiftLanguageMode(.v6)] + debugSwiftOptimization
        ),
        .target(
            name: "RFBRenderingC",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: debugCOptimization
        ),

        // MARK: - rootshellVNC (public API facade, SwiftUI views, input handling)
        .target(
            name: "rootshellVNC",
            dependencies: ["RFBProtocol", "RFBTransport", "RFBRendering"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)] + debugSwiftOptimization
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
