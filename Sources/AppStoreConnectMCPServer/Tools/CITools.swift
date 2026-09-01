import AppStoreConnectKit
import Foundation
import MCP

/// The Xcode Cloud read tools exposed by this MCP server.
enum CITools {
    // MARK: - Tool catalog

    static let all: [Tool] = [
        Tool(
            name: "asc_ci_list_products",
            description: """
                List Xcode Cloud products (one per app with Xcode Cloud configured). \
                Optionally filter to a single App Store Connect app id.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app_id": .object([
                        "type": .string("string"),
                        "description": .string("App Store Connect app id to filter by (optional)."),
                    ])
                ]),
            ])
        ),
        Tool(
            name: "asc_ci_list_workflows",
            description: "List the Xcode Cloud workflows for a product.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "product_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud product id (from asc_ci_list_products)."),
                    ])
                ]),
                "required": .array([.string("product_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_list_build_runs",
            description: "List recent build runs for a workflow, newest first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workflow_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud workflow id (from asc_ci_list_workflows)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max build runs to return (default 20)."),
                    ]),
                ]),
                "required": .array([.string("workflow_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_get_build_run",
            description: "Fetch a build run plus its actions (build/analyze/test/archive steps) with issue counts.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_run_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud build run id."),
                    ])
                ]),
                "required": .array([.string("build_run_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_get_issues",
            description: "List the issues (errors, warnings, analyzer findings) for one build action.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud build action id (from asc_ci_get_build_run)."),
                    ])
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_get_test_results",
            description: "List the test results for one build action.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud build action id."),
                    ])
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_get_artifacts",
            description: "List downloadable artifacts (log bundle, xcresult, products) for one build action, with signed URLs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_action_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud build action id."),
                    ])
                ]),
                "required": .array([.string("build_action_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_failure_report",
            description: """
                Aggregate everything about a failed build run into one payload: for every \
                non-succeeded action, its issues (with file/line), failed tests, and artifact \
                download URLs. Use this to reason about what broke without further round-trips.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "build_run_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud build run id."),
                    ]),
                    "workflow_name": .object([
                        "type": .string("string"),
                        "description": .string("Optional workflow name to embed for context."),
                    ]),
                ]),
                "required": .array([.string("build_run_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    static func call(name: String, arguments: [String: Value]) async throws -> CallTool.Result {
        let client = try makeClient()

        switch name {
        case "asc_ci_list_products":
            let appID = arguments["app_id"]?.stringValue
            return try json(await client.ciProducts(appID: appID))

        case "asc_ci_list_workflows":
            let productID = try require(arguments, "product_id")
            return try json(await client.ciWorkflows(productID: productID))

        case "asc_ci_list_build_runs":
            let workflowID = try require(arguments, "workflow_id")
            let limit = arguments["limit"]?.intValue ?? 20
            return try json(await client.ciBuildRuns(workflowID: workflowID, limit: limit))

        case "asc_ci_get_build_run":
            let id = try require(arguments, "build_run_id")
            async let run = client.ciBuildRun(id: id)
            async let actions = client.ciBuildActions(buildRunID: id)
            let payload = BuildRunDetail(run: try await run.data, actions: try await actions.data)
            return try json(payload)

        case "asc_ci_get_issues":
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciIssues(buildActionID: id))

        case "asc_ci_get_test_results":
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciTestResults(buildActionID: id))

        case "asc_ci_get_artifacts":
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciArtifacts(buildActionID: id))

        case "asc_ci_failure_report":
            let id = try require(arguments, "build_run_id")
            let workflowName = arguments["workflow_name"]?.stringValue
            return try json(await client.ciFailureReport(buildRunID: id, workflowName: workflowName))

        default:
            return .init(content: [.text("Unknown tool: \(name)")], isError: true)
        }
    }

    // MARK: - Helpers

    private struct BuildRunDetail: Encodable {
        let run: CIBuildRun
        let actions: [CIBuildAction]
    }

    private static func makeClient() throws -> AppStoreConnectClient {
        guard let credentials = ASCCredentials.fromEnvironment() else {
            throw ASCError.invalidConfiguration(
                reason: """
                    Missing App Store Connect credentials. Set ASC_KEY_ID, ASC_ISSUER_ID, and \
                    either ASC_PRIVATE_KEY (raw .p8 PEM) or ASC_PRIVATE_KEY_PATH.
                    """
            )
        }
        return AppStoreConnectClient(credentials: credentials)
    }

    private static func require(_ arguments: [String: Value], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw ASCError.invalidConfiguration(reason: "Missing required argument '\(key)'.")
        }
        return value
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: false)
    }
}
