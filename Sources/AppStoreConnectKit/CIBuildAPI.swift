import Foundation

// MARK: - Xcode Cloud (App Store Connect CI) read API
//
// Thin, typed convenience methods over the generic `get` on `AppStoreConnectClient`.
// All are read-only; diagnosing a failure is left to the caller.

extension AppStoreConnectClient {
    /// Lists Xcode Cloud products, optionally filtered to one app.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id (`filter[app]`). Pass `nil` for all products.
    ///   - limit: Maximum products to return across all pages.
    public func ciProducts(appID: String? = nil, limit: Int = 200) async throws -> ASCListResponse<CIProduct> {
        var query: [String: String] = [:]
        if let appID { query["filter[app]"] = appID }
        return try await getAll("/v1/ciProducts", query: query, limit: limit)
    }

    /// Lists workflows for an Xcode Cloud product.
    public func ciWorkflows(productID: String, limit: Int = 200) async throws -> ASCListResponse<CIWorkflow> {
        try await getAll("/v1/ciProducts/\(productID)/workflows", limit: limit)
    }

    /// Fetches a single workflow by id, including its `actions` (with per-test-action
    /// test-plan configuration).
    public func ciWorkflow(id: String) async throws -> ASCResponse<CIWorkflow> {
        try await get("/v1/ciWorkflows/\(id)")
    }

    /// Lists build runs for a workflow, newest first.
    ///
    /// - Parameters:
    ///   - workflowID: The workflow id.
    ///   - limit: Maximum runs to return.
    ///   - failedOnly: When `true`, return only runs whose `completionStatus` is a
    ///     failure (`FAILED` / `ERRORED` / `INVALID`). The App Store Connect API has
    ///     no status filter, so this over-fetches recent runs and filters client-side;
    ///     `limit` still caps the result.
    public func ciBuildRuns(
        workflowID: String,
        limit: Int = 20,
        failedOnly: Bool = false
    ) async throws -> ASCListResponse<CIBuildRun> {
        guard failedOnly else {
            return try await getAll(
                "/v1/ciWorkflows/\(workflowID)/buildRuns",
                query: ["sort": "-number"],
                limit: limit
            )
        }

        let overFetch = min(AppStoreConnectClient.maxPageSize, max(limit * 5, 50))
        let page: ASCListResponse<CIBuildRun> = try await getAll(
            "/v1/ciWorkflows/\(workflowID)/buildRuns",
            query: ["sort": "-number"],
            limit: overFetch
        )
        let failed = page.data.filter(\.isFailure)
        return ASCListResponse(data: Array(failed.prefix(limit)), links: page.links)
    }

    /// Fetches a single build run by id.
    public func ciBuildRun(id: String) async throws -> ASCResponse<CIBuildRun> {
        try await get("/v1/ciBuildRuns/\(id)")
    }

    /// Lists the actions (build / analyze / test / archive steps) of a build run.
    public func ciBuildActions(buildRunID: String, limit: Int = 200) async throws -> ASCListResponse<CIBuildAction> {
        try await getAll("/v1/ciBuildRuns/\(buildRunID)/actions", limit: limit)
    }

    /// Lists the issues (errors / warnings / analyzer findings) for a build action.
    public func ciIssues(buildActionID: String, limit: Int = 200) async throws -> ASCListResponse<CIIssue> {
        try await getAll("/v1/ciBuildActions/\(buildActionID)/issues", limit: limit)
    }

    /// Lists the test results for a build action.
    public func ciTestResults(buildActionID: String, limit: Int = 200) async throws -> ASCListResponse<CITestResult> {
        try await getAll("/v1/ciBuildActions/\(buildActionID)/testResults", limit: limit)
    }

    /// Lists the downloadable artifacts (log bundle, xcresult, products) for a build action.
    public func ciArtifacts(buildActionID: String, limit: Int = 200) async throws -> ASCListResponse<CIArtifact> {
        try await getAll("/v1/ciBuildActions/\(buildActionID)/artifacts", limit: limit)
    }

    /// Summarizes the test plans a workflow runs, derived from its `TEST` actions.
    ///
    /// Xcode Cloud has no `ciTestPlans` resource — a test plan is only visible via a
    /// test action's `testConfiguration`. This fetches the workflow and flattens that.
    public func ciTestPlans(workflowID: String) async throws -> CITestPlanSummary {
        let workflow = try await ciWorkflow(id: workflowID).data
        let testActions = (workflow.attributes?.actions ?? [])
            .filter { ($0.actionType ?? "").uppercased() == "TEST" }
            .map { action in
                CITestPlanSummary.TestAction(
                    actionName: action.name,
                    scheme: action.scheme,
                    selectionKind: action.testConfiguration?.kind,
                    testPlanNames: (action.testConfiguration?.testPlans ?? []).compactMap(\.name)
                )
            }
        return CITestPlanSummary(
            workflowID: workflowID,
            workflowName: workflow.attributes?.name,
            testActions: testActions
        )
    }
}

/// The test plans configured for a workflow, flattened from its `TEST` actions.
public struct CITestPlanSummary: Codable, Sendable {
    public let workflowID: String
    public let workflowName: String?
    public let testActions: [TestAction]

    /// De-duplicated union of every test-plan name across all test actions.
    public var allTestPlanNames: [String] {
        var seen = Set<String>()
        return testActions.flatMap(\.testPlanNames).filter { seen.insert($0).inserted }
    }

    public init(workflowID: String, workflowName: String?, testActions: [TestAction]) {
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.testActions = testActions
    }

    public struct TestAction: Codable, Sendable {
        public let actionName: String?
        public let scheme: String?
        /// How the test plans were chosen: `USE_SCHEME_SETTINGS`, `SPECIFIC_TEST_PLANS`, …
        public let selectionKind: String?
        public let testPlanNames: [String]

        public init(actionName: String?, scheme: String?, selectionKind: String?, testPlanNames: [String]) {
            self.actionName = actionName
            self.scheme = scheme
            self.selectionKind = selectionKind
            self.testPlanNames = testPlanNames
        }
    }
}

// MARK: - Aggregated failure report

/// A single normalized failure report for a build run, gathering everything an
/// agent needs to reason about *what broke* without making further round-trips.
public struct CIFailureReport: Codable, Sendable {
    public let buildRunID: String
    public let workflowName: String?
    public let number: Int?
    public let completionStatus: String?
    public let sourceCommitSha: String?
    public let sourceCommitMessage: String?
    public let startedDate: String?
    public let finishedDate: String?
    /// Wall-clock seconds the run took. A value at or near the Xcode Cloud ceiling
    /// (7200s / 120 min) is the immediate signal for a timeout rather than a code failure.
    public let durationSeconds: Double?
    public let failedActions: [FailedAction]

    public struct FailedAction: Codable, Sendable {
        public let id: String
        public let name: String?
        public let actionType: String?
        public let completionStatus: String?
        public let startedDate: String?
        public let finishedDate: String?
        public let durationSeconds: Double?
        public let issues: [Issue]
        public let failedTests: [FailedTest]
        public let artifacts: [Artifact]

        public struct Issue: Codable, Sendable {
            public let type: String?
            public let message: String?
            public let path: String?
            public let line: Int?
        }

        public struct FailedTest: Codable, Sendable {
            public let className: String?
            public let name: String?
            public let status: String?
            public let message: String?
        }

        public struct Artifact: Codable, Sendable {
            public let fileType: String?
            public let fileName: String?
            public let downloadUrl: String?
        }
    }
}

extension AppStoreConnectClient {
    /// Builds a ``CIFailureReport`` for a build run: for every non-succeeded action,
    /// collects its issues, failed tests, and artifact download URLs.
    ///
    /// - Parameters:
    ///   - buildRunID: The build run id.
    ///   - workflowName: Optional workflow name to embed in the report for context.
    public func ciFailureReport(buildRunID: String, workflowName: String? = nil) async throws -> CIFailureReport {
        let run = try await ciBuildRun(id: buildRunID).data
        let actions = try await ciBuildActions(buildRunID: buildRunID).data

        var failed: [CIFailureReport.FailedAction] = []

        for action in actions where action.isUnsuccessful {

            // Sequential on purpose: keeps ordering deterministic and avoids
            // firing 3 concurrent requests per failed action at a rate-limited API.
            let issuesResp = try await ciIssues(buildActionID: action.id)
            let testsResp = try await ciTestResults(buildActionID: action.id)
            let artifactsResp = try await ciArtifacts(buildActionID: action.id)

            let issues = issuesResp.data.map { issue in
                CIFailureReport.FailedAction.Issue(
                    type: issue.attributes?.issueType,
                    message: issue.attributes?.message,
                    path: issue.attributes?.fileSource?.path,
                    line: issue.attributes?.fileSource?.lineNumber
                )
            }
            let failedTests =
                testsResp.data
                .filter { ($0.attributes?.status ?? "").uppercased().contains("FAIL") }
                .map { result in
                    CIFailureReport.FailedAction.FailedTest(
                        className: result.attributes?.className,
                        name: result.attributes?.name,
                        status: result.attributes?.status,
                        message: result.attributes?.message
                    )
                }
            let artifacts = artifactsResp.data.map { artifact in
                CIFailureReport.FailedAction.Artifact(
                    fileType: artifact.attributes?.fileType,
                    fileName: artifact.attributes?.fileName,
                    downloadUrl: artifact.attributes?.downloadUrl
                )
            }

            failed.append(
                CIFailureReport.FailedAction(
                    id: action.id,
                    name: action.attributes?.name,
                    actionType: action.attributes?.actionType,
                    completionStatus: action.attributes?.completionStatus,
                    startedDate: action.attributes?.startedDate,
                    finishedDate: action.attributes?.finishedDate,
                    durationSeconds: action.durationSeconds,
                    issues: issues,
                    failedTests: failedTests,
                    artifacts: artifacts
                )
            )
        }

        return CIFailureReport(
            buildRunID: buildRunID,
            workflowName: workflowName,
            number: run.attributes?.number,
            completionStatus: run.attributes?.completionStatus,
            sourceCommitSha: run.attributes?.sourceCommit?.commitSha,
            sourceCommitMessage: run.attributes?.sourceCommit?.message,
            startedDate: run.attributes?.startedDate,
            finishedDate: run.attributes?.finishedDate,
            durationSeconds: run.durationSeconds,
            failedActions: failed
        )
    }
}
