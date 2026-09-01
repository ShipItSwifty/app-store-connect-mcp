import Foundation

// MARK: - Xcode Cloud (App Store Connect CI) read API
//
// Thin, typed convenience methods over the generic `get` on `AppStoreConnectClient`.
// All are read-only; diagnosing a failure is left to the caller.

extension AppStoreConnectClient {
    /// Lists Xcode Cloud products, optionally filtered to one app.
    ///
    /// - Parameter appID: App Store Connect app id (`filter[app]`). Pass `nil` for all products.
    public func ciProducts(appID: String? = nil, limit: Int = 50) async throws -> ASCListResponse<CIProduct> {
        var query = ["limit": String(limit)]
        if let appID { query["filter[app]"] = appID }
        return try await get("/v1/ciProducts", query: query)
    }

    /// Lists workflows for an Xcode Cloud product.
    public func ciWorkflows(productID: String, limit: Int = 50) async throws -> ASCListResponse<CIWorkflow> {
        try await get("/v1/ciProducts/\(productID)/workflows", query: ["limit": String(limit)])
    }

    /// Lists build runs for a workflow, newest first.
    public func ciBuildRuns(workflowID: String, limit: Int = 20) async throws -> ASCListResponse<CIBuildRun> {
        try await get(
            "/v1/ciWorkflows/\(workflowID)/buildRuns",
            query: ["limit": String(limit), "sort": "-number"]
        )
    }

    /// Fetches a single build run by id.
    public func ciBuildRun(id: String) async throws -> ASCResponse<CIBuildRun> {
        try await get("/v1/ciBuildRuns/\(id)")
    }

    /// Lists the actions (build / analyze / test / archive steps) of a build run.
    public func ciBuildActions(buildRunID: String, limit: Int = 50) async throws -> ASCListResponse<CIBuildAction> {
        try await get("/v1/ciBuildRuns/\(buildRunID)/actions", query: ["limit": String(limit)])
    }

    /// Lists the issues (errors / warnings / analyzer findings) for a build action.
    public func ciIssues(buildActionID: String, limit: Int = 200) async throws -> ASCListResponse<CIIssue> {
        try await get("/v1/ciBuildActions/\(buildActionID)/issues", query: ["limit": String(limit)])
    }

    /// Lists the test results for a build action.
    public func ciTestResults(buildActionID: String, limit: Int = 200) async throws -> ASCListResponse<CITestResult> {
        try await get("/v1/ciBuildActions/\(buildActionID)/testResults", query: ["limit": String(limit)])
    }

    /// Lists the downloadable artifacts (log bundle, xcresult, products) for a build action.
    public func ciArtifacts(buildActionID: String, limit: Int = 50) async throws -> ASCListResponse<CIArtifact> {
        try await get("/v1/ciBuildActions/\(buildActionID)/artifacts", query: ["limit": String(limit)])
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
    public let failedActions: [FailedAction]

    public struct FailedAction: Codable, Sendable {
        public let id: String
        public let name: String?
        public let actionType: String?
        public let completionStatus: String?
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

        let failedStatuses: Set<String> = ["FAILED", "ERRORED", "CANCELED", "INVALID"]
        var failed: [CIFailureReport.FailedAction] = []

        for action in actions {
            let status = action.attributes?.completionStatus ?? ""
            guard failedStatuses.contains(status.uppercased()) else { continue }

            async let issuesResp = ciIssues(buildActionID: action.id)
            async let testsResp = ciTestResults(buildActionID: action.id)
            async let artifactsResp = ciArtifacts(buildActionID: action.id)

            let issues = try await issuesResp.data.map { issue in
                CIFailureReport.FailedAction.Issue(
                    type: issue.attributes?.issueType,
                    message: issue.attributes?.message,
                    path: issue.attributes?.fileSource?.path,
                    line: issue.attributes?.fileSource?.lineNumber
                )
            }
            let failedTests = try await testsResp.data
                .filter { ($0.attributes?.status ?? "").uppercased().contains("FAIL") }
                .map { result in
                    CIFailureReport.FailedAction.FailedTest(
                        className: result.attributes?.className,
                        name: result.attributes?.name,
                        status: result.attributes?.status,
                        message: result.attributes?.message
                    )
                }
            let artifacts = try await artifactsResp.data.map { artifact in
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
            failedActions: failed
        )
    }
}
