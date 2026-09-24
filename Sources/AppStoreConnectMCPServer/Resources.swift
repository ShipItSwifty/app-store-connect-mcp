import AppStoreConnectKit
import Foundation
import MCP

/// Resource templates exposed by the MCP server.
enum MCPResources {
    static let templates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: "asc://apps/{bundle_id}/latest-failure",
            name: "asc_latest_failure",
            description: "The latest failed Xcode Cloud build report for an App Store Connect app.",
            mimeType: "application/json"
        )
    ]

    static func read(
        uri: String,
        makeClient: CITools.ClientProvider
    ) async throws -> ReadResource.Result {
        let bundleID = try bundleID(from: uri)
        let client = try makeClient()
        let app = try await client.app(bundleID: bundleID)
        let report = try await client.ciLatestFailureReport(appID: app.id)
        let data = try JSONEncoder().encode(report)
        return .init(contents: [
            .text(
                String(decoding: data, as: UTF8.self),
                uri: uri,
                mimeType: "application/json"
            )
        ])
    }

    private static func bundleID(from uri: String) throws -> String {
        guard let components = URLComponents(string: uri),
            components.scheme == "asc",
            components.host == "apps",
            components.query == nil,
            components.fragment == nil
        else {
            throw ASCError.invalidConfiguration(
                reason: "Resource URI must match asc://apps/{bundle_id}/latest-failure."
            )
        }

        let prefix = "/"
        let suffix = "/latest-failure"
        guard components.percentEncodedPath.hasPrefix(prefix),
            components.percentEncodedPath.hasSuffix(suffix)
        else {
            throw ASCError.invalidConfiguration(
                reason: "Resource URI must match asc://apps/{bundle_id}/latest-failure."
            )
        }

        let encodedBundleID = String(
            components.percentEncodedPath.dropFirst(prefix.count).dropLast(suffix.count)
        )
        guard let bundleID = encodedBundleID.removingPercentEncoding, !bundleID.isEmpty,
            !bundleID.contains("/")
        else {
            throw ASCError.invalidConfiguration(reason: "Resource URI contains an invalid bundle_id.")
        }
        return bundleID
    }
}
