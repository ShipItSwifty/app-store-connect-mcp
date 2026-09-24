import AppStoreConnectKit
import Foundation
import MCP

/// One MCP resource (or resource template) and the read-only tool that serves it.
///
/// Resources are the same data the tools return, addressed by URI instead of by a
/// call, so a host can attach one to a conversation (in Claude Code, `@`-mention it)
/// without the model spending a turn on a tool call. Each reads through an existing
/// ``ToolSpec``: a URI's `{placeholders}` become that tool's arguments, and there is
/// no second implementation to drift from the first.
struct ResourceSpec: Sendable {
    /// A concrete URI (`asc://apps`) or an RFC 6570 level-1 template
    /// (`asc://apps/{app_id}/builds`), whose placeholders are tool argument names.
    let uriTemplate: String
    let name: String
    let title: String
    let description: String
    /// The read-only tool that produces the resource's JSON.
    let tool: String

    static let mimeType = "application/json"

    var isTemplate: Bool { uriTemplate.contains("{") }

    /// The placeholder names in ``uriTemplate``, in order.
    var placeholders: [String] {
        segments(of: uriTemplate).compactMap(Self.placeholder(in:))
    }

    var resource: Resource {
        Resource(name: name, uri: uriTemplate, title: title, description: description, mimeType: Self.mimeType)
    }

    var template: Resource.Template {
        Resource.Template(
            uriTemplate: uriTemplate,
            name: name,
            title: title,
            description: description,
            mimeType: Self.mimeType
        )
    }

    /// The tool arguments `uri` binds, or `nil` when it isn't an instance of this spec.
    func match(_ uri: String) -> [String: Value]? {
        let pattern = segments(of: uriTemplate)
        let candidate = segments(of: uri)
        guard pattern.count == candidate.count else { return nil }

        var arguments: [String: Value] = [:]
        for (expected, actual) in zip(pattern, candidate) {
            if let key = Self.placeholder(in: expected) {
                guard let value = actual.removingPercentEncoding, !value.isEmpty else { return nil }
                arguments[key] = .string(value)
            } else if expected != actual {
                return nil
            }
        }
        return arguments
    }

    private func segments(of uri: String) -> [String] {
        uri.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func placeholder(in segment: String) -> String? {
        guard segment.count > 2, segment.hasPrefix("{"), segment.hasSuffix("}") else { return nil }
        return String(segment.dropFirst().dropLast())
    }
}

/// The resources this server exposes: a few fixed ones for the lookups an agent
/// starts from, and templates for the per-app and per-run reports.
enum ServerResources {
    static let specs: [ResourceSpec] = [
        ResourceSpec(
            uriTemplate: "asc://apps",
            name: "apps",
            title: "Apps",
            description: "Every app this API key can see: app id, bundle id, name, SKU, primary locale.",
            tool: "asc_list_apps"
        ),
        ResourceSpec(
            uriTemplate: "asc://signing-assets",
            name: "signing-assets",
            title: "Signing assets",
            description: "Certificates and provisioning profiles, flagging expired, expiring, and invalid ones.",
            tool: "asc_signing_assets"
        ),
        ResourceSpec(
            uriTemplate: "asc://rate-limit",
            name: "rate-limit",
            title: "Rate limit",
            description: "This key's App Store Connect hourly rate-limit position.",
            tool: "asc_rate_limit_status"
        ),
        ResourceSpec(
            uriTemplate: "asc://apps/{app_id}/ci/latest-failure",
            name: "ci-latest-failure",
            title: "Latest Xcode Cloud failure",
            description: "The app's most recent failed Xcode Cloud build run with its aggregated failure report.",
            tool: "asc_ci_latest_failure"
        ),
        ResourceSpec(
            uriTemplate: "asc://apps/{app_id}/versions",
            name: "app-store-versions",
            title: "App Store versions",
            description: "The app's App Store versions, newest first, with review state.",
            tool: "asc_list_app_store_versions"
        ),
        ResourceSpec(
            uriTemplate: "asc://apps/{app_id}/builds",
            name: "builds",
            title: "Builds",
            description: "The app's uploaded builds, newest first, with processing and export-compliance state.",
            tool: "asc_list_builds"
        ),
        ResourceSpec(
            uriTemplate: "asc://bundles/{bundle_id}/submission-status",
            name: "submission-status",
            title: "Submission status",
            description: "Where the app's latest App Store version stands in review, and the next step.",
            tool: "asc_submission_status"
        ),
        ResourceSpec(
            uriTemplate: "asc://bundles/{bundle_id}/testflight",
            name: "testflight-status",
            title: "TestFlight status",
            description: "The newest build's internal and external TestFlight availability and What to Test notes.",
            tool: "asc_testflight_build_status"
        ),
        ResourceSpec(
            uriTemplate: "asc://ci/build-runs/{build_run_id}/failure-report",
            name: "ci-failure-report",
            title: "Build run failure report",
            description: "Every failed action of one Xcode Cloud build run: issues with file/line, failed tests, artifacts.",
            tool: "asc_ci_failure_report"
        ),
    ]

    /// Fixed resources, for `resources/list`.
    static let resources: [Resource] = specs.filter { !$0.isTemplate }.map(\.resource)

    /// Parameterized resources, for `resources/templates/list`.
    static let templates: [Resource.Template] = specs.filter(\.isTemplate).map(\.template)

    /// Serves `resources/read` by running the tool behind the matching spec.
    ///
    /// - Throws: `MCPError.invalidParams` for a URI no spec matches, and
    ///   `MCPError.internalError` carrying the tool's message when the read fails, so
    ///   the host shows *why* (missing credentials, a 403 on a key's role, …).
    static func read(
        uri: String,
        makeClient: @escaping CITools.ClientProvider = CITools.defaultClient
    ) async throws -> ReadResource.Result {
        for spec in specs {
            guard let arguments = spec.match(uri) else { continue }

            let result: CallTool.Result
            do {
                result = try await CITools.call(name: spec.tool, arguments: arguments, makeClient: makeClient)
            } catch let error as ASCError {
                throw MCPError.internalError("App Store Connect error: \(error.localizedDescription)")
            }

            // The first block is the payload; a second is the rate-limit heads-up,
            // which is advice for a model mid-investigation, not part of the resource.
            let texts = result.content.compactMap { block -> String? in
                if case .text(let text, _, _) = block { return text }
                return nil
            }
            if result.isError == true {
                throw MCPError.internalError(texts.joined(separator: "\n"))
            }
            guard let payload = texts.first else {
                throw MCPError.internalError("\(spec.tool) returned no content for \(uri)")
            }
            return ReadResource.Result(contents: [.text(payload, uri: uri, mimeType: ResourceSpec.mimeType)])
        }
        throw MCPError.invalidParams("Unknown resource: \(uri)")
    }
}
