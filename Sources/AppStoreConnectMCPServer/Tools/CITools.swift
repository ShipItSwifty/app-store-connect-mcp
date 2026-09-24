import AppStoreConnectKit
import Foundation
import MCP
import Synchronization

/// The App Store Connect read/diagnostic tools exposed by this MCP server.
///
/// Every tool is read-only. The server performs no analysis of its own beyond the
/// normalization done in `AppStoreConnectKit` (`CIFailureReport`, `CILogParser`,
/// `AppStoreSubmissionService`); the MCP host agent does the reasoning.
///
/// Each tool is a ``ToolSpec`` carrying both its schema and its handler, so the
/// advertised catalog and the dispatcher are the same list.
enum CITools {
    /// How the dispatcher obtains an `AppStoreConnectClient`. Overridable in tests.
    typealias ClientProvider = @Sendable () throws -> AppStoreConnectClient

    // MARK: - Tool catalog

    static let specs: [ToolSpec] = specs(writesEnabled: WriteTools.isEnabled())

    /// The catalog for a given write setting.
    ///
    /// Writes are opt-in (`ASC_ENABLE_WRITES`), so a default deployment advertises a
    /// catalog whose every tool is `readOnlyHint: true` and can be auto-approved
    /// wholesale. Taking the flag as a parameter keeps that decision testable.
    static func specs(writesEnabled: Bool) -> [ToolSpec] {
        let readOnly =
            ciSpecs + AppStoreTools.specs + DiagnosticsTools.specs + ReviewTools.specs + ReportingTools.specs
        return writesEnabled ? readOnly + WriteTools.specs : readOnly
    }

    /// The Xcode Cloud half of the catalog. ``specs`` is this plus
    /// ``AppStoreTools/specs`` — one list, split across two files only for size.
    private static let ciSpecs: [ToolSpec] = [
        ToolSpec(
            name: "asc_ci_list_products",
            description: """
                List Xcode Cloud products (one per app with Xcode Cloud configured). \
                Optionally filter to a single App Store Connect app id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id to filter by (optional).")
            ]
        ) { args, makeClient in
            try json(await makeClient().ciProducts(appID: args.string("app_id")))
        },

        ToolSpec(
            name: "asc_ci_list_workflows",
            description: "List the Xcode Cloud workflows for a product.",
            arguments: [
                .string("product_id", "Xcode Cloud product id (from asc_ci_list_products).", required: true)
            ]
        ) { args, makeClient in
            try json(await makeClient().ciWorkflows(productID: args.require("product_id")))
        },

        ToolSpec(
            name: "asc_ci_list_build_runs",
            description: "List recent build runs for a workflow, newest first.",
            arguments: [
                .string("workflow_id", "Xcode Cloud workflow id (from asc_ci_list_workflows).", required: true),
                .integer("limit", "Max build runs to return (default 20)."),
                .boolean(
                    "failed_only",
                    "When true, return only runs whose completionStatus is FAILED/ERRORED/INVALID "
                        + "(recent runs are over-fetched and filtered client-side; 'limit' still caps the result). "
                        + "Use this to skip past long stretches of green builds."
                ),
            ]
        ) { args, makeClient in
            try json(
                await makeClient().ciBuildRuns(
                    workflowID: args.require("workflow_id"),
                    limit: args.int("limit", default: 20),
                    failedOnly: args.bool("failed_only")
                ))
        },

        ToolSpec(
            name: "asc_ci_list_test_plans",
            description: """
                List the test plans a workflow runs, flattened from its TEST actions: \
                per action the scheme, the selection kind (USE_SCHEME_SETTINGS / SPECIFIC_TEST_PLANS / …), \
                and the test-plan names. Use this to diagnose test-target routing (e.g. which \
                .xctestplan Xcode Cloud actually executed).
                """,
            arguments: [
                .string("workflow_id", "Xcode Cloud workflow id (from asc_ci_list_workflows).", required: true)
            ]
        ) { args, makeClient in
            try json(await makeClient().ciTestPlans(workflowID: args.require("workflow_id")))
        },

        ToolSpec(
            name: "asc_ci_get_build_run",
            description: "Fetch a build run plus its actions (build/analyze/test/archive steps) with issue counts.",
            arguments: [
                .string("build_run_id", "Xcode Cloud build run id.", required: true)
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let id = try args.require("build_run_id")
            async let run = client.ciBuildRun(id: id)
            async let actions = client.ciBuildActions(buildRunID: id)
            return try json(BuildRunDetail(run: try await run.data, actions: try await actions.data))
        },

        ToolSpec(
            name: "asc_ci_get_issues",
            description: "List the issues (errors, warnings, analyzer findings) for one build action.",
            arguments: [
                .string("build_action_id", "Xcode Cloud build action id (from asc_ci_get_build_run).", required: true)
            ]
        ) { args, makeClient in
            try json(await makeClient().ciIssues(buildActionID: args.require("build_action_id")))
        },

        ToolSpec(
            name: "asc_ci_get_test_results",
            description: "List the test results for one build action.",
            arguments: [
                .string("build_action_id", "Xcode Cloud build action id.", required: true)
            ]
        ) { args, makeClient in
            try json(await makeClient().ciTestResults(buildActionID: args.require("build_action_id")))
        },

        ToolSpec(
            name: "asc_ci_get_artifacts",
            description:
                "List downloadable artifacts (log bundle, xcresult, products) for one build action, with signed URLs.",
            arguments: [
                .string("build_action_id", "Xcode Cloud build action id.", required: true)
            ]
        ) { args, makeClient in
            try json(await makeClient().ciArtifacts(buildActionID: args.require("build_action_id")))
        },

        ToolSpec(
            name: "asc_ci_failure_report",
            description: """
                Aggregate everything about a failed build run into one payload: for every \
                non-succeeded action, its issues (with file/line), failed tests, and artifact \
                download URLs. Use this to reason about what broke without further round-trips.
                """,
            arguments: [
                .string("build_run_id", "Xcode Cloud build run id.", required: true),
                .string("workflow_name", "Optional workflow name to embed for context."),
            ],
            outputSchema: reportOutputSchema
        ) { args, makeClient in
            try json(
                await makeClient().ciFailureReport(
                    buildRunID: args.require("build_run_id"),
                    workflowName: args.string("workflow_name")
                ))
        },

        ToolSpec(
            name: "asc_ci_failure_report_with_logs",
            description: """
                Like asc_ci_failure_report, but also downloads every failed action's text-log \
                artifacts and parses them into structured findings (compiler errors, linker \
                failures, code-signing errors, per-test failures) with file/line where available. \
                Binary artifacts (xcresult, zipped log bundles) are listed under skippedArtifacts.
                """,
            arguments: [
                .string("build_run_id", "Xcode Cloud build run id.", required: true),
                .string("workflow_name", "Optional workflow name to embed for context."),
            ],
            outputSchema: failureReportWithLogsOutputSchema
        ) { args, makeClient in
            try json(
                await makeClient().ciFailureReportWithLogs(
                    buildRunID: args.require("build_run_id"),
                    workflowName: args.string("workflow_name")
                ))
        },

        ToolSpec(
            name: "asc_ci_latest_failure",
            description: """
                Triage shortcut. Given an app id, product id, or workflow id, find the \
                most recent failed build run and return its aggregated failure report \
                (every failed action's issues with file/line, failed tests, and artifact \
                download URLs) plus the resolved workflow and build_run_id. Collapses the \
                products → workflows → build runs → run → issues walk into one call. \
                Returns {"found": false} when nothing has failed in the scanned workflows. \
                For parsed log text, feed the returned build_run_id to \
                asc_ci_failure_report_with_logs.
                """,
            arguments: [
                .string("workflow_id", "Xcode Cloud workflow id — scan just this workflow (most specific)."),
                .string("product_id", "Xcode Cloud product id — scan every workflow of this product."),
                .string(
                    "app_id",
                    "App Store Connect app id — scan every workflow of every Xcode Cloud product of this app."
                ),
            ],
            outputSchema: latestFailureOutputSchema
        ) { args, makeClient in
            try json(
                await makeClient().ciLatestFailureReport(
                    workflowID: args.string("workflow_id"),
                    productID: args.string("product_id"),
                    appID: args.string("app_id")
                ))
        },

        ToolSpec(
            name: "asc_ci_analyze_log",
            description: """
                Parse raw CI log text (or a downloaded text artifact) into structured findings: \
                compiler errors/warnings, linker errors, code-signing errors, fatal errors, and \
                test failures, each with file/line when present. Provide either 'text' or \
                'download_url' (a signed URL from asc_ci_get_artifacts / asc_ci_failure_report).
                """,
            arguments: [
                .string("text", "Raw log text to analyze."),
                .string("download_url", "Signed artifact URL to download and analyze as text."),
            ]
        ) { args, makeClient in
            if let text = args.string("text") {
                return try json(CILogParser().parse(text))
            }
            let downloadURL = try args.require("download_url")
            return try json(await makeClient().analyzeArtifactLog(from: downloadURL))
        },

        ToolSpec(
            name: "asc_submission_status",
            description: """
                Diagnose where an app's latest App Store version stands in review: the version's \
                own state (REJECTED, METADATA_REJECTED, INVALID_BINARY, WAITING_FOR_REVIEW, …), the \
                review submission state, per-item outcomes, whether the developer needs to act, and \
                a plain-language explanation of the likely next step.
                """,
            arguments: [
                .string("bundle_id", "The app's bundle identifier (e.g. com.example.app).", required: true)
            ],
            outputSchema: submissionStatusOutputSchema
        ) { args, makeClient in
            let service = AppStoreSubmissionService(client: try makeClient())
            return try json(await service.status(bundleID: args.require("bundle_id")))
        },
    ]

    /// The tools advertised to the MCP host.
    static let all: [Tool] = specs.map(\.tool)

    /// Specs keyed by name, for dispatch.
    private static let specsByName: [String: ToolSpec] = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.name, $0) }
    )

    // MARK: - Dispatch

    /// Runs a tool, then appends a rate-limit heads-up block when the last client
    /// used is close to App Store Connect's hourly throttle point. The agent sees
    /// this as a second text block and can pause broad scans before it stalls.
    static func call(
        name: String,
        arguments: [String: Value],
        makeClient: ClientProvider = CITools.defaultClient
    ) async throws -> CallTool.Result {
        // The provider is a synchronous `@Sendable` closure, so it cannot await an
        // actor to record what it built; a mutex is the smallest thing that lets it
        // hand the limiter back. Only the first client of a call is kept — a tool
        // makes at most one.
        let probe = Mutex<RateLimiter?>(nil)
        let provider: ClientProvider = {
            let client = try makeClient()
            probe.withLock { limiter in
                if limiter == nil { limiter = client.rateLimiter }
            }
            return client
        }

        let result = try await dispatch(name: name, arguments: arguments, makeClient: provider)

        guard let limiter = probe.withLock({ $0 }),
            let status = await limiter.status(),
            status.isNearLimit
        else { return result }

        let hint =
            "⚠️ App Store Connect API rate limit: \(status.usedPercent)% used "
            + "(\(status.remaining)/\(status.limit) requests left this hour). "
            + "Requests pause automatically at \(Int((status.throttleThreshold * 100).rounded()))% — "
            + "consider narrowing further calls."
        return .init(
            content: result.content + [.plainText(hint)],
            structuredContent: result.structuredContent,
            isError: result.isError,
            _meta: result._meta
        )
    }

    /// Looks a tool up by name and runs its handler.
    static func dispatch(
        name: String,
        arguments: [String: Value],
        makeClient: ClientProvider
    ) async throws -> CallTool.Result {
        guard let spec = specsByName[name] else {
            // A write tool that exists but is switched off should say so; only a name
            // this server has never heard of is "unknown".
            if let disabled = WriteTools.specsByName[name] {
                return .init(content: [.plainText(WriteTools.disabledMessage(for: disabled.name))], isError: true)
            }
            return .init(content: [.plainText("Unknown tool: \(name)")], isError: true)
        }
        return try await spec.handler(ToolArguments(arguments), makeClient)
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

    /// The client every tool call in this process shares, built on first use.
    ///
    /// One client per process rather than one per call: the client owns the cached
    /// JWT and the ``RateLimiter``, so a fresh client per call re-read the `.p8`,
    /// re-signed a token, and started every call with no idea how close the key was
    /// to Apple's hourly limit — which made the rate-limit heads-up blind to anything
    /// but the call in hand. A missing-credentials failure is not cached, so fixing
    /// the environment and retrying works without restarting the server.
    private static let sharedClient = Mutex<AppStoreConnectClient?>(nil)

    static let defaultClient: ClientProvider = {
        try sharedClient.withLock { cached in
            if let client = cached { return client }
            guard let credentials = ASCCredentials.fromEnvironment() else {
                throw ASCError.invalidConfiguration(
                    reason: """
                        Missing App Store Connect credentials. Set ASC_KEY_ID, ASC_ISSUER_ID, and \
                        either ASC_PRIVATE_KEY (raw .p8 PEM) or ASC_PRIVATE_KEY_PATH.
                        """
                )
            }
            let client = AppStoreConnectClient(credentials: credentials)
            cached = client
            return client
        }
    }

    /// Encodes a tool's payload as one text block.
    static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let structuredContent = try JSONDecoder().decode(Value.self, from: data)
        return try CallTool.Result(
            content: [.plainText(String(decoding: data, as: UTF8.self))],
            structuredContent: structuredContent,
            isError: false
        )
    }

    // MARK: - Output schemas

    /// `CIFailureReport`.
    static let reportOutputSchema = objectSchema(
        properties: [
            "buildRunID": nullable("string"),
            "workflowName": nullable("string"),
            "number": nullable("integer"),
            "completionStatus": nullable("string"),
            "sourceCommitSha": nullable("string"),
            "sourceCommitMessage": nullable("string"),
            "startedDate": nullable("string"),
            "finishedDate": nullable("string"),
            "durationSeconds": nullable("number"),
            "failedActions": arraySchema(of: failureActionSchema),
        ],
        required: ["buildRunID", "failedActions"]
    )

    /// `CIFailureReportWithLogs`.
    static let failureReportWithLogsOutputSchema = objectSchema(
        properties: [
            "report": reportOutputSchema,
            "logFindingsByAction": objectSchema(
                properties: [:],
                additionalProperties: logAnalysisSchema
            ),
            "skippedArtifacts": arraySchema(of: .string("string")),
        ],
        required: ["report", "logFindingsByAction", "skippedArtifacts"]
    )

    /// `CILatestFailure`.
    static let latestFailureOutputSchema = objectSchema(
        properties: [
            "found": .string("boolean"),
            "workflowsScanned": .string("integer"),
            "workflowID": nullable("string"),
            "workflowName": nullable("string"),
            "buildRunID": nullable("string"),
            "report": nullableObject(reportOutputSchema),
        ],
        required: ["found", "workflowsScanned"]
    )

    /// `ReportingTools.AnalyticsCatalog`.
    static let analyticsCatalogOutputSchema = objectSchema(
        properties: [
            "appID": .string("string"),
            "requests": arraySchema(of: analyticsRequestSchema),
        ],
        required: ["appID", "requests"]
    )

    /// `ReportingTools.AnalyticsReportPayload`.
    static let analyticsReportOutputSchema = objectSchema(
        properties: [
            "found": .string("boolean"),
            "report": nullableObject(
                objectSchema(
                    properties: [
                        "reportName": nullable("string"),
                        "category": nullable("string"),
                        "granularity": nullable("string"),
                        "processingDate": nullable("string"),
                        "table": reportTableSchema,
                    ],
                    required: ["table"]
                )
            ),
        ],
        required: ["found"]
    )

    /// `ReportingTools.SalesReportPayload`.
    static let salesReportOutputSchema = objectSchema(
        properties: [
            "found": .string("boolean"),
            "table": nullableObject(reportTableSchema),
        ],
        required: ["found"]
    )

    /// `AppStoreTools.RateLimitReport`.
    static let rateLimitOutputSchema = objectSchema(
        properties: [
            "known": .string("boolean"),
            "status": nullableObject(
                objectSchema(
                    properties: [
                        "limit": .string("integer"),
                        "remaining": .string("integer"),
                        "usedFraction": .string("number"),
                        "throttleThreshold": .string("number"),
                    ],
                    required: ["limit", "remaining", "usedFraction", "throttleThreshold"]
                )
            ),
        ],
        required: ["known"]
    )

    /// `AppStoreSubmissionService.SubmissionStatusReport`.
    static let submissionStatusOutputSchema = objectSchema(
        properties: [
            "appID": .string("string"),
            "bundleID": .string("string"),
            "latestVersion": nullableObject(submissionVersionSchema),
            "reviewSubmission": nullableObject(reviewSubmissionSchema),
            "items": arraySchema(of: reviewSubmissionItemSchema),
            "needsDeveloperAction": .string("boolean"),
            "diagnosis": .string("string"),
            "buildAttached": nullable("boolean"),
            "attachedBuild": nullableObject(submissionBuildSchema),
            "candidateBuild": nullableObject(submissionBuildSchema),
        ],
        required: ["appID", "bundleID", "items", "needsDeveloperAction", "diagnosis"]
    )

    /// `DiagnosticLogSummary`.
    static let diagnosticLogSummaryOutputSchema = objectSchema(
        properties: [
            "signatureID": nullable("string"),
            "reports": arraySchema(of: diagnosticReportSchema),
        ],
        required: ["reports"]
    )

    /// `PerfPowerMetricsSummary`, plus the raw fields returned when `raw` is true.
    static let perfPowerMetricsOutputSchema = objectSchema(
        properties: [
            "regressions": arraySchema(of: metricsRegressionSchema),
            "metrics": arraySchema(of: metricsPointSchema),
            "version": nullable("string"),
            "insights": nullableObject(objectSchema(properties: [:], additionalProperties: true)),
            "productData": arraySchema(of: objectSchema(properties: [:], additionalProperties: true)),
        ],
        additionalProperties: false
    )

    /// `AppStoreTools.TestFlightBuildStatus`.
    static let testFlightBuildStatusOutputSchema = objectSchema(
        properties: [
            "found": .string("boolean"),
            "build": nullableObject(objectSchema(properties: [:], additionalProperties: true)),
            "betaDetail": nullableObject(objectSchema(properties: [:], additionalProperties: true)),
            "whatToTest": arraySchema(of: objectSchema(properties: [:], additionalProperties: true)),
        ],
        required: ["found", "whatToTest"]
    )

    private static let failureActionSchema = objectSchema(
        properties: [
            "id": .string("string"),
            "name": nullable("string"),
            "actionType": nullable("string"),
            "completionStatus": nullable("string"),
            "startedDate": nullable("string"),
            "finishedDate": nullable("string"),
            "durationSeconds": nullable("number"),
            "issues": arraySchema(
                of: objectSchema(
                    properties: [
                        "type": nullable("string"),
                        "message": nullable("string"),
                        "path": nullable("string"),
                        "line": nullable("integer"),
                    ]
                )),
            "failedTests": arraySchema(
                of: objectSchema(
                    properties: [
                        "className": nullable("string"),
                        "name": nullable("string"),
                        "status": nullable("string"),
                        "message": nullable("string"),
                    ]
                )),
            "artifacts": arraySchema(
                of: objectSchema(
                    properties: [
                        "fileType": nullable("string"),
                        "fileName": nullable("string"),
                        "downloadUrl": nullable("string"),
                    ]
                )),
        ],
        required: ["id", "issues", "failedTests", "artifacts"]
    )

    private static let logAnalysisSchema = objectSchema(
        properties: [
            "findings": arraySchema(
                of: objectSchema(
                    properties: [
                        "kind": .string("string"),
                        "message": .string("string"),
                        "path": nullable("string"),
                        "line": nullable("integer"),
                        "rawLine": .string("string"),
                    ],
                    required: ["kind", "message", "rawLine"]
                )),
            "linesScanned": .string("integer"),
        ],
        required: ["findings", "linesScanned"]
    )

    private static let analyticsRequestSchema = objectSchema(
        properties: [
            "request": objectSchema(
                properties: [
                    "id": .string("string"),
                    "attributes": nullableObject(
                        objectSchema(
                            properties: [
                                "accessType": nullable("string"),
                                "stoppedDueToInactivity": nullable("boolean"),
                            ]
                        )),
                ],
                required: ["id"]
            ),
            "reports": arraySchema(
                of: objectSchema(
                    properties: [
                        "id": .string("string"),
                        "attributes": nullableObject(
                            objectSchema(
                                properties: [
                                    "name": nullable("string"),
                                    "category": nullable("string"),
                                ]
                            )),
                    ],
                    required: ["id"]
                )),
        ],
        required: ["request", "reports"]
    )

    private static let reportTableSchema = objectSchema(
        properties: [
            "columns": arraySchema(of: .string("string")),
            "rows": arraySchema(of: arraySchema(of: .string("string"))),
            "totalRows": .string("integer"),
            "truncated": .string("boolean"),
        ],
        required: ["columns", "rows", "totalRows", "truncated"]
    )

    private static let submissionBuildSchema = objectSchema(
        properties: [
            "id": .string("string"),
            "version": nullable("string"),
            "processingState": nullable("string"),
            "expired": nullable("boolean"),
            "buildAudienceType": nullable("string"),
            "audienceNote": nullable("string"),
        ],
        required: ["id"]
    )

    private static let submissionVersionSchema = objectSchema(
        properties: [
            "id": .string("string"),
            "versionString": nullable("string"),
            "platform": nullable("string"),
            "state": nullable("string"),
            "createdDate": nullable("string"),
        ],
        required: ["id"]
    )

    private static let reviewSubmissionSchema = objectSchema(
        properties: [
            "id": .string("string"),
            "state": nullable("string"),
            "platform": nullable("string"),
            "submittedDate": nullable("string"),
        ],
        required: ["id"]
    )

    private static let reviewSubmissionItemSchema = objectSchema(
        properties: [
            "id": .string("string"),
            "state": nullable("string"),
        ],
        required: ["id"]
    )

    private static let diagnosticReportSchema = objectSchema(
        properties: [
            "appVersion": nullable("string"),
            "buildVersion": nullable("string"),
            "osVersion": nullable("string"),
            "deviceType": nullable("string"),
            "event": nullable("string"),
            "eventDetail": nullable("string"),
            "writesCaused": nullable("string"),
            "blameFrames": arraySchema(
                of: objectSchema(
                    properties: [
                        "symbolName": nullable("string"),
                        "binaryName": nullable("string"),
                        "fileName": nullable("string"),
                        "lineNumber": nullable("string"),
                        "sampleCount": nullable("integer"),
                        "depth": .string("integer"),
                    ],
                    required: ["depth"]
                )),
            "totalFrames": .string("integer"),
        ],
        required: ["blameFrames", "totalFrames"]
    )

    private static let metricsRegressionSchema = objectSchema(
        properties: [
            "metric": nullable("string"),
            "category": nullable("string"),
            "summary": nullable("string"),
            "highImpact": nullable("boolean"),
            "latestVersion": nullable("string"),
            "worstDeltaPercentage": nullable("number"),
        ]
    )

    private static let metricsPointSchema = objectSchema(
        properties: [
            "category": nullable("string"),
            "metric": nullable("string"),
            "platform": nullable("string"),
            "device": nullable("string"),
            "percentile": nullable("string"),
            "version": nullable("string"),
            "value": nullable("number"),
            "unit": nullable("string"),
            "goal": nullable("string"),
        ]
    )

    private static func objectSchema(
        properties: [String: Value],
        required: [String] = [],
        additionalProperties: Value = .bool(false)
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": additionalProperties,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func arraySchema(of items: Value) -> Value {
        .object(["type": .string("array"), "items": items])
    }

    private static func nullable(_ type: String) -> Value {
        .array([.string(type), .string("null")])
    }

    private static func nullableObject(_ schema: Value) -> Value {
        .object([
            "anyOf": .array([
                schema,
                .object(["type": .string("null")]),
            ])
        ])
    }
}
