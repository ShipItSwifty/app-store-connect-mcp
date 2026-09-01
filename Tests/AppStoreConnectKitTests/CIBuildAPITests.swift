import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("Xcode Cloud read API", .serialized)
struct CIBuildAPITests {
    @Test("Decodes build runs newest-first list")
    func decodesBuildRuns() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    [
                        "id": "run-2",
                        "attributes": [
                            "number": 2,
                            "executionProgress": "COMPLETE",
                            "completionStatus": "FAILED",
                            "sourceCommit": ["commitSha": "abc123", "message": "break the build"],
                        ],
                    ],
                    [
                        "id": "run-1",
                        "attributes": ["number": 1, "completionStatus": "SUCCEEDED"],
                    ],
                ]
            ])
        ])
        let runs = try await client.ciBuildRuns(workflowID: "wf-1")
        #expect(runs.data.map(\.id) == ["run-2", "run-1"])
        #expect(runs.data.first?.attributes?.completionStatus == "FAILED")
        #expect(runs.data.first?.attributes?.sourceCommit?.commitSha == "abc123")
    }

    @Test("Failure report aggregates issues, failed tests, and artifacts for failed actions")
    func failureReport() async throws {
        let client = makeClient(responses: [
            // ciBuildRun(id:)
            .json([
                "data": [
                    "id": "run-9",
                    "attributes": ["number": 9, "completionStatus": "FAILED", "sourceCommit": ["commitSha": "deadbeef"]],
                ]
            ]),
            // ciBuildActions(buildRunID:)
            .json([
                "data": [
                    ["id": "act-build", "attributes": ["name": "Build", "actionType": "BUILD", "completionStatus": "FAILED"]],
                    ["id": "act-test", "attributes": ["name": "Test", "actionType": "TEST", "completionStatus": "SUCCEEDED"]],
                ]
            ]),
            // issues for act-build
            .json([
                "data": [
                    [
                        "id": "iss-1",
                        "attributes": [
                            "issueType": "ERROR",
                            "message": "use of unresolved identifier 'foo'",
                            "fileSource": ["path": "Sources/App/Foo.swift", "lineNumber": 42],
                        ],
                    ]
                ]
            ]),
            // test results for act-build
            .json(["data": [String]()]),
            // artifacts for act-build
            .json([
                "data": [
                    [
                        "id": "art-1",
                        "attributes": ["fileType": "LOG_BUNDLE", "fileName": "logs.zip", "downloadUrl": "https://example/logs"],
                    ]
                ]
            ]),
        ])

        let report = try await client.ciFailureReport(buildRunID: "run-9", workflowName: "Release")
        #expect(report.number == 9)
        #expect(report.workflowName == "Release")
        #expect(report.sourceCommitSha == "deadbeef")
        #expect(report.failedActions.count == 1)
        let action = try #require(report.failedActions.first)
        #expect(action.actionType == "BUILD")
        #expect(action.issues.first?.path == "Sources/App/Foo.swift")
        #expect(action.issues.first?.line == 42)
        #expect(action.artifacts.first?.downloadUrl == "https://example/logs")
    }
}
