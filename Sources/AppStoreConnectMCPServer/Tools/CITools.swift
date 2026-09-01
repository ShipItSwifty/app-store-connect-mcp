import AppStoreConnectKit
import Foundation
import MCP

/// The App Store Connect read/diagnostic tools exposed by this MCP server.
///
/// Every tool is read-only. The server performs no analysis of its own beyond the
/// normalization done in `AppStoreConnectKit` (`CIFailureReport`, `CILogParser`,
/// `AppStoreSubmissionService`); the MCP host agent does the reasoning.
enum CITools {
    /// How the dispatcher obtains an `AppStoreConnectClient`. Overridable in tests.
    typealias ClientProvider = @Sendable () throws -> AppStoreConnectClient

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
                    "failed_only": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "When true, return only runs whose completionStatus is FAILED/ERRORED/INVALID "
                                + "(recent runs are over-fetched and filtered client-side; 'limit' still caps the result). "
                                + "Use this to skip past long stretches of green builds."),
                    ]),
                ]),
                "required": .array([.string("workflow_id")]),
            ])
        ),
        Tool(
            name: "asc_ci_list_test_plans",
            description: """
                List the test plans a workflow runs, flattened from its TEST actions: \
                per action the scheme, the selection kind (USE_SCHEME_SETTINGS / SPECIFIC_TEST_PLANS / …), \
                and the test-plan names. Use this to diagnose test-target routing (e.g. which \
                .xctestplan Xcode Cloud actually executed).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "workflow_id": .object([
                        "type": .string("string"),
                        "description": .string("Xcode Cloud workflow id (from asc_ci_list_workflows)."),
                    ])
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
        Tool(
            name: "asc_ci_failure_report_with_logs",
            description: """
                Like asc_ci_failure_report, but also downloads every failed action's text-log \
                artifacts and parses them into structured findings (compiler errors, linker \
                failures, code-signing errors, per-test failures) with file/line where available. \
                Binary artifacts (xcresult, zipped log bundles) are listed under skippedArtifacts.
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
        Tool(
            name: "asc_ci_analyze_log",
            description: """
                Parse raw CI log text (or a downloaded text artifact) into structured findings: \
                compiler errors/warnings, linker errors, code-signing errors, fatal errors, and \
                test failures, each with file/line when present. Provide either 'text' or \
                'download_url' (a signed URL from asc_ci_get_artifacts / asc_ci_failure_report).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Raw log text to analyze."),
                    ]),
                    "download_url": .object([
                        "type": .string("string"),
                        "description": .string("Signed artifact URL to download and analyze as text."),
                    ]),
                ]),
            ])
        ),
        Tool(
            name: "asc_submission_status",
            description: """
                Diagnose where an app's latest App Store version stands in review: the version's \
                own state (REJECTED, METADATA_REJECTED, INVALID_BINARY, WAITING_FOR_REVIEW, …), the \
                review submission state, per-item outcomes, whether the developer needs to act, and \
                a plain-language explanation of the likely next step.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("The app's bundle identifier (e.g. com.example.app)."),
                    ])
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    /// Runs a tool, then appends a rate-limit heads-up block when the last client
    /// used is close to App Store Connect's hourly throttle point. The agent sees
    /// this as a second text block and can pause broad scans before it stalls.
    static func call(
        name: String,
        arguments: [String: Value],
        makeClient: ClientProvider = CITools.defaultClient
    ) async throws -> CallTool.Result {
        let probe = ClientProbe()
        let provider: ClientProvider = {
            let client = try makeClient()
            probe.capture(client.rateLimiter)
            return client
        }

        let result = try await dispatch(name: name, arguments: arguments, makeClient: provider)

        guard let limiter = probe.rateLimiter,
            let status = await limiter.status(),
            status.isNearLimit
        else { return result }

        let hint =
            "⚠️ App Store Connect API rate limit: \(status.usedPercent)% used "
            + "(\(status.remaining)/\(status.limit) requests left this hour). "
            + "Requests pause automatically at \(Int((status.throttleThreshold * 100).rounded()))% — "
            + "consider narrowing further calls."
        return .init(content: result.content + [.text(hint)], isError: result.isError)
    }

    /// Holds the `RateLimiter` of the client the current call constructed, if any.
    /// The provider closure is `@Sendable`; a lock-guarded box keeps the capture legal.
    private final class ClientProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var limiter: RateLimiter?

        func capture(_ limiter: RateLimiter) {
            lock.lock()
            defer { lock.unlock() }
            if self.limiter == nil { self.limiter = limiter }
        }

        var rateLimiter: RateLimiter? {
            lock.lock()
            defer { lock.unlock() }
            return limiter
        }
    }

    static func dispatch(
        name: String,
        arguments: [String: Value],
        makeClient: ClientProvider
    ) async throws -> CallTool.Result {
        switch name {
        case "asc_ci_list_products":
            let client = try makeClient()
            let appID = arguments["app_id"]?.stringValue
            return try json(await client.ciProducts(appID: appID))

        case "asc_ci_list_workflows":
            let client = try makeClient()
            let productID = try require(arguments, "product_id")
            return try json(await client.ciWorkflows(productID: productID))

        case "asc_ci_list_build_runs":
            let client = try makeClient()
            let workflowID = try require(arguments, "workflow_id")
            let limit = arguments["limit"]?.intValue ?? 20
            let failedOnly =
                arguments["failed_only"]?.boolValue
                ?? (arguments["failed_only"]?.stringValue == "true")
            return try json(
                await client.ciBuildRuns(workflowID: workflowID, limit: limit, failedOnly: failedOnly))

        case "asc_ci_list_test_plans":
            let client = try makeClient()
            let workflowID = try require(arguments, "workflow_id")
            return try json(await client.ciTestPlans(workflowID: workflowID))

        case "asc_ci_get_build_run":
            let client = try makeClient()
            let id = try require(arguments, "build_run_id")
            async let run = client.ciBuildRun(id: id)
            async let actions = client.ciBuildActions(buildRunID: id)
            let payload = BuildRunDetail(run: try await run.data, actions: try await actions.data)
            return try json(payload)

        case "asc_ci_get_issues":
            let client = try makeClient()
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciIssues(buildActionID: id))

        case "asc_ci_get_test_results":
            let client = try makeClient()
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciTestResults(buildActionID: id))

        case "asc_ci_get_artifacts":
            let client = try makeClient()
            let id = try require(arguments, "build_action_id")
            return try json(await client.ciArtifacts(buildActionID: id))

        case "asc_ci_failure_report":
            let client = try makeClient()
            let id = try require(arguments, "build_run_id")
            let workflowName = arguments["workflow_name"]?.stringValue
            return try json(await client.ciFailureReport(buildRunID: id, workflowName: workflowName))

        case "asc_ci_failure_report_with_logs":
            let client = try makeClient()
            let id = try require(arguments, "build_run_id")
            let workflowName = arguments["workflow_name"]?.stringValue
            return try json(await client.ciFailureReportWithLogs(buildRunID: id, workflowName: workflowName))

        case "asc_ci_analyze_log":
            if let text = arguments["text"]?.stringValue, !text.isEmpty {
                return try json(CILogParser().parse(text))
            }
            let downloadURL = try require(arguments, "download_url")
            let client = try makeClient()
            return try json(await client.analyzeArtifactLog(from: downloadURL))

        case "asc_submission_status":
            let client = try makeClient()
            let bundleID = try require(arguments, "bundle_id")
            let service = AppStoreSubmissionService(client: client)
            return try json(await service.status(bundleID: bundleID))

        default:
            return .init(content: [.text("Unknown tool: \(name)")], isError: true)
        }
    }

    // MARK: - Helpers

    /// `asc_ci_get_build_run` payload: the run and its actions, plus computed
    /// durations so a timeout (a run near Xcode Cloud's 120-minute ceiling) is
    /// obvious without the agent having to diff two ISO-8601 strings.
    private struct BuildRunDetail: Encodable {
        let run: CIBuildRun
        let actions: [CIBuildAction]

        enum CodingKeys: String, CodingKey {
            case run, actions, durationSeconds, actionDurationsSeconds
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(run, forKey: .run)
            try container.encode(actions, forKey: .actions)
            try container.encodeIfPresent(run.durationSeconds, forKey: .durationSeconds)
            let actionDurations = actions.reduce(into: [String: Double]()) { acc, action in
                if let seconds = action.durationSeconds { acc[action.id] = seconds }
            }
            if !actionDurations.isEmpty {
                try container.encode(actionDurations, forKey: .actionDurationsSeconds)
            }
        }
    }

    static let defaultClient: ClientProvider = {
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

    static func require(_ arguments: [String: Value], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw ASCError.invalidConfiguration(reason: "Missing required argument '\(key)'.")
        }
        return value
    }

    static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], isError: false)
    }
}
