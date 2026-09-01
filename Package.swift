// swift-tools-version: 6.0
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
        .package(url: "https://github.com/apple/swift-crypto", from: "4.4.0"),
        .package(url: "https://github.com/vapor/jwt-kit", from: "5.4.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.12.0"),
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", from: "0.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "AppStoreConnectKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Logging", package: "swift-log"),
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
    ],
    swiftLanguageModes: [.v6]
)
