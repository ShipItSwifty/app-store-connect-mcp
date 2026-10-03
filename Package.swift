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
        // JWTKit 5.7.1 requires Crypto 4.x even though swift-certificates now accepts 5.x.
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
        .package(url: "https://github.com/vapor/jwt-kit", .upToNextMajor(from: "5.7.1")),
        .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", from: "0.7.0"),
        // Dependencies of the vendored MCP target below.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(url: "https://github.com/mattt/eventsource.git", from: "1.5.1"),
        // Documentation only; contributes no code to any product.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        // Keep the patched SDK in this package so versioned downstream dependencies
        // resolve without an unsupported local package dependency.
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "EventSource",
                    package: "eventsource",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])
                ),
            ],
            path: "Vendor/swift-sdk/Sources/MCP"
        ),
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
                "MCP",
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
                "MCP",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
