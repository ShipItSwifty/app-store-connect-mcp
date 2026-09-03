import Foundation

// MARK: - Xcode Cloud writes
//
// The one write the CI side of the API offers: starting a build run. Everything
// else under `ci*` is read-only.

extension AppStoreConnectClient {
    /// Starts a build run for a workflow.
    ///
    /// - Parameters:
    ///   - workflowID: The workflow to run.
    ///   - gitReferenceID: Optional `scmGitReferences` id — the branch or tag to build.
    ///     Omit to use the workflow's own start condition.
    ///   - clean: Force a clean build, discarding the derived-data cache.
    /// - Returns: The created build run, whose `number` and `executionProgress` can be
    ///   polled with ``ciBuildRun(id:)``.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` — a 409 usually means the
    ///   workflow is disabled or the git reference does not exist.
    @discardableResult
    public func startCIBuildRun(
        workflowID: String,
        gitReferenceID: String? = nil,
        clean: Bool? = nil
    ) async throws -> CIBuildRun {
        let relationships = CIBuildRunCreateBody.Data.Relationships(
            workflow: .init(data: .init(type: "ciWorkflows", id: workflowID)),
            buildRun: nil,
            sourceBranchOrTag: gitReferenceID.map { .init(data: .init(type: "scmGitReferences", id: $0)) }
        )
        let body = CIBuildRunCreateBody(
            data: .init(
                type: "ciBuildRuns",
                attributes: clean.map { CIBuildRunCreateBody.Data.Attributes(clean: $0) },
                relationships: relationships
            )
        )
        let response: ASCResponse<CIBuildRun> = try await post("/v1/ciBuildRuns", body: body)
        return response.data
    }

    /// Re-runs an existing build run, reusing its workflow and git reference.
    ///
    /// This is the "try that again" path: pointing at the previous run means the retry
    /// builds the same commit, which a fresh run of the workflow would not guarantee.
    @discardableResult
    public func rerunCIBuildRun(buildRunID: String, clean: Bool? = nil) async throws -> CIBuildRun {
        let body = CIBuildRunCreateBody(
            data: .init(
                type: "ciBuildRuns",
                attributes: clean.map { CIBuildRunCreateBody.Data.Attributes(clean: $0) },
                relationships: .init(
                    workflow: nil,
                    buildRun: .init(data: .init(type: "ciBuildRuns", id: buildRunID)),
                    sourceBranchOrTag: nil
                )
            )
        )
        let response: ASCResponse<CIBuildRun> = try await post("/v1/ciBuildRuns", body: body)
        return response.data
    }
}

/// `POST /v1/ciBuildRuns` body. Relationships are omitted when absent, since Apple
/// rejects a null relationship rather than ignoring it.
private struct CIBuildRunCreateBody: Encodable, Sendable {
    let data: Data

    struct Data: Encodable, Sendable {
        let type: String
        let attributes: Attributes?
        let relationships: Relationships

        struct Attributes: Encodable, Sendable {
            let clean: Bool
        }

        struct Relationships: Encodable, Sendable {
            let workflow: Relationship?
            let buildRun: Relationship?
            let sourceBranchOrTag: Relationship?

            struct Relationship: Encodable, Sendable {
                let data: Identifier

                struct Identifier: Encodable, Sendable {
                    let type: String
                    let id: String
                }
            }
        }
    }
}
