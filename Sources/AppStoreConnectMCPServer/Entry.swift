import AppStoreConnectKit
import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MCP server exposing the Xcode Cloud (App Store Connect CI) read API.
///
/// The server itself performs no analysis — it is driven by an AI agent (the MCP
/// host), which calls these tools to gather data and reason about *what broke in CI*.
///
/// Credentials are read from the environment: `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
/// either `ASC_PRIVATE_KEY` (raw PEM) or `ASC_PRIVATE_KEY_PATH`.
@main
struct AppStoreConnectMCP {
    static func main() async throws {
        var log = Logger(label: "app-store-connect-mcp")
        log.logLevel = .info

        let server = Server(
            name: "app-store-connect-mcp",
            version: ASCMCPVersion.current,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: CITools.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                return try await CITools.call(name: params.name, arguments: params.arguments ?? [:])
            } catch let error as ASCError {
                return .init(content: [.text("App Store Connect error: \(error.localizedDescription)")], isError: true)
            } catch {
                return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
            }
        }

        let transport = StdioTransport(logger: log)
        try await server.start(transport: transport)
        log.info("app-store-connect-mcp ready on stdio")

        // Keep the process alive; the transport runs the stdio read loop.
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    }
}

enum ASCMCPVersion {
    static let current = "0.1.0"
}
