import Foundation

// MARK: - Latest-failure convenience
//
// One call that goes from a scope (app / product / workflow) to "what broke in the
// last red build", instead of walking products → workflows → build runs → run →
// issues by hand.

/// The most recent failed build run for a scope, with its aggregated report.
///
/// Returned by ``AppStoreConnectClient/ciLatestFailureReport(workflowID:productID:appID:)``.
/// When `found` is `false` only `workflowsScanned` is meaningful.
public struct CILatestFailure: Codable, Sendable {
    /// Whether any failed run was found in the scanned workflows.
    public let found: Bool
    /// How many workflows were scanned to answer the query.
    public let workflowsScanned: Int
    /// The workflow the selected run belongs to.
    public let workflowID: String?
    public let workflowName: String?
    /// The failed run that was selected: newest by `startedDate`, then `createdDate`.
    public let buildRunID: String?
    /// The aggregated failure report for `buildRunID` — every failed action's issues
    /// (with file/line), failed tests, and artifact download URLs.
    public let report: CIFailureReport?

    /// A "nothing has failed" result.
    public static func none(workflowsScanned: Int) -> CILatestFailure {
        CILatestFailure(
            found: false,
            workflowsScanned: workflowsScanned,
            workflowID: nil,
            workflowName: nil,
            buildRunID: nil,
            report: nil
        )
    }

    public init(
        found: Bool,
        workflowsScanned: Int,
        workflowID: String?,
        workflowName: String?,
        buildRunID: String?,
        report: CIFailureReport?
    ) {
        self.found = found
        self.workflowsScanned = workflowsScanned
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.buildRunID = buildRunID
        self.report = report
    }
}

extension AppStoreConnectClient {
    /// Finds the most recent failed build run reachable from the given scope and
    /// returns its ``CIFailureReport`` in one call.
    ///
    /// Scope resolution (first non-nil wins):
    /// - `workflowID` — scanned directly.
    /// - `productID` — every workflow of that product is scanned.
    /// - `appID` — every workflow of every Xcode Cloud product of that app is scanned.
    ///
    /// For each candidate workflow the newest failed run (`FAILED` / `ERRORED` /
    /// `INVALID`) is fetched; the newest of those across all workflows — by
    /// `startedDate`, falling back to `createdDate` — is reported. Build `number`
    /// is per-workflow and is deliberately **not** used for the cross-workflow
    /// comparison.
    ///
    /// - Throws: ``ASCError/invalidConfiguration(reason:)`` when none of
    ///   `workflowID` / `productID` / `appID` is supplied, or when a request fails.
    public func ciLatestFailureReport(
        workflowID: String? = nil,
        productID: String? = nil,
        appID: String? = nil
    ) async throws -> CILatestFailure {
        let workflows = try await ciResolveWorkflows(
            workflowID: workflowID, productID: productID, appID: appID)

        var best: (id: String, name: String?, run: CIBuildRun)?
        for workflow in workflows {
            let failed = try await ciBuildRuns(workflowID: workflow.id, limit: 1, failedOnly: true)
            guard let run = failed.data.first else { continue }
            if let current = best, !Self.isNewer(run, than: current.run) { continue }
            best = (workflow.id, workflow.attributes?.name, run)
        }

        guard let best else { return .none(workflowsScanned: workflows.count) }

        let report = try await ciFailureReport(buildRunID: best.run.id, workflowName: best.name)
        return CILatestFailure(
            found: true,
            workflowsScanned: workflows.count,
            workflowID: best.id,
            workflowName: best.name,
            buildRunID: best.run.id,
            report: report
        )
    }

    /// Resolves the workflow set a latest-failure scan should cover.
    private func ciResolveWorkflows(
        workflowID: String?,
        productID: String?,
        appID: String?
    ) async throws -> [CIWorkflow] {
        if let workflowID {
            return [try await ciWorkflow(id: workflowID).data]
        }
        if let productID {
            return try await ciWorkflows(productID: productID).data
        }
        if let appID {
            let products = try await ciProducts(appID: appID).data
            var workflows: [CIWorkflow] = []
            for product in products {
                workflows += try await ciWorkflows(productID: product.id).data
            }
            return workflows
        }
        throw ASCError.invalidConfiguration(
            reason: "ciLatestFailureReport needs one of workflow_id, product_id, or app_id."
        )
    }

    /// Newer-than by `startedDate`, then `createdDate`. A run with a parseable date
    /// always beats one without.
    private static func isNewer(_ lhs: CIBuildRun, than rhs: CIBuildRun) -> Bool {
        let left = CIDate.parse(lhs.attributes?.startedDate) ?? CIDate.parse(lhs.attributes?.createdDate)
        let right = CIDate.parse(rhs.attributes?.startedDate) ?? CIDate.parse(rhs.attributes?.createdDate)
        switch (left, right) {
        case (let left?, let right?): return left > right
        case (.some, nil): return true
        case (nil, _): return false
        }
    }
}
