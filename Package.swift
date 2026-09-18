// swift-tools-version: 6.3
// app-store-connect-mcp — a reusable App Store Connect / Xcode Cloud client and an MCP server.

import PackageDescription

let package = Package(
    name: "app-store-connect-mcp",
    platforms: [.macOS(.v15)],
    products: [
        // Cross-platform App Store Connect API client, auth, DTOs, and the Xcode Cloud read API.
        .library(name: "AppStoreConnectKit", targets: ["AppStoreConnectKit"]),
        // macOS-only: IPA upload orchestration (shells out to `xcrun altool`).
        .library(name: "AppStoreConnectUploadKit", targets: ["AppStoreConnectUploadKit"]),
        // MCP server exposing the Xcode Cloud read API to an AI agent.
        .executable(name: "app-store-connect-mcp", targets: ["AppStoreConnectMCPServer"]),
    ],
    dependencies: [
        // Blocked on swift-crypto 5.0.0: jwt-kit's own manifest has no crypto upper bound,
        // but it pulls in apple/swift-certificates (for X509), which still hard-pins
        // swift-crypto to "3.12.3"..<"5.0.0" as of swift-certificates 1.20.0 (2026-09) and
        // even on its main branch — the only opt-in is SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA,
        // which itself excludes the final 5.0.0 tag (upper bound is "5.0.0-beta.max" < "5.0.0").
        // Re-attempt once swift-certificates ships crypto-5.0 support.
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
        .package(url: "https://github.com/vapor/jwt-kit", .upToNextMajor(from: "5.7.1")),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.0"),
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", from: "0.5.0"),
        // Pin the SDK fix for object-valued experimental capabilities sent by Codex.
        // Return to upstream once a release includes this decoding fix.
        .package(
            url: "https://github.com/maniramezan/swift-sdk.git",
            revision: "46dec85bd63c1e4909718b024d243bc92c7d403d"
        ),
        // Documentation only; contributes no code to any product.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        // Linux has no `Compression` framework; ZipArchive falls back to zlib there.
        .systemLibrary(name: "CZlib"),
        .target(
            name: "AppStoreConnectKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Logging", package: "swift-log"),
                .target(name: "CZlib", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "AppStoreConnectUploadKit",
            dependencies: [
                "AppStoreConnectKit",
                .product(name: "SwiftyShell", package: "SwiftyShell"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "AppStoreConnectMCPServer",
            dependencies: [
                "AppStoreConnectKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AppStoreConnectKitTests",
            dependencies: [
                "AppStoreConnectKit",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AppStoreConnectUploadKitTests",
            dependencies: [
                "AppStoreConnectUploadKit",
                "AppStoreConnectKit",
                .product(name: "SwiftyShell", package: "SwiftyShell"),
            ]
        ),
        .testTarget(
            name: "AppStoreConnectMCPServerTests",
            dependencies: [
                "AppStoreConnectMCPServer",
                "AppStoreConnectKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
