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

    @Test("failedOnly over-fetches and returns only failed runs, capped at limit")
    func failedOnlyFilter() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: observed,
            responses: [
                .json([
                    "data": [
                        ["id": "run-5", "attributes": ["number": 5, "completionStatus": "SUCCEEDED"]],
                        ["id": "run-4", "attributes": ["number": 4, "completionStatus": "FAILED"]],
                        ["id": "run-3", "attributes": ["number": 3, "completionStatus": "SUCCEEDED"]],
                        ["id": "run-2", "attributes": ["number": 2, "completionStatus": "ERRORED"]],
                        ["id": "run-1", "attributes": ["number": 1, "completionStatus": "INVALID"]],
                    ]
                ])
            ]
        )

        let runs = try await client.ciBuildRuns(workflowID: "wf-1", limit: 2, failedOnly: true)
        #expect(runs.data.map(\.id) == ["run-4", "run-2"])
        // over-fetched: asked the API for more than the caller's limit of 2.
        #expect(observed.value.first?.contains("/buildRuns") == true)
    }

    @Test("ciTestPlans flattens TEST actions and their test-plan names")
    func testPlans() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    "id": "wf-1",
                    "attributes": [
                        "name": "Release",
                        "actions": [
                            ["name": "Build", "actionType": "BUILD"],
                            [
                                "name": "Test iOS", "actionType": "TEST", "scheme": "AppScheme",
                                "testConfiguration": [
                                    "kind": "SPECIFIC_TEST_PLANS",
                                    "testPlans": [["name": "Smoke"], ["name": "Full"]],
                                ],
                            ],
                        ],
                    ],
                ]
            ])
        ])

        let summary = try await client.ciTestPlans(workflowID: "wf-1")
        #expect(summary.workflowName == "Release")
        #expect(summary.testActions.count == 1)
        let action = try #require(summary.testActions.first)
        #expect(action.scheme == "AppScheme")
        #expect(action.selectionKind == "SPECIFIC_TEST_PLANS")
        #expect(action.testPlanNames == ["Smoke", "Full"])
        #expect(summary.allTestPlanNames == ["Smoke", "Full"])
    }

    @Test("Failure report computes run and action durations from started/finished dates")
    func failureReportDurations() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    "id": "run-1",
                    "attributes": [
                        "number": 1, "completionStatus": "FAILED",
                        "startedDate": "2026-09-01T12:00:00Z",
                        "finishedDate": "2026-09-01T14:00:00Z",
                    ],
                ]
            ]),
            .json([
                "data": [
                    [
                        "id": "act-1",
                        "attributes": [
                            "name": "Build", "actionType": "BUILD", "completionStatus": "FAILED",
                            "startedDate": "2026-09-01T12:05:00Z",
                            "finishedDate": "2026-09-01T12:35:00Z",
                        ],
                    ]
                ]
            ]),
            .json(["data": [String]()]),
            .json(["data": [String]()]),
            .json(["data": [String]()]),
        ])

        let report = try await client.ciFailureReport(buildRunID: "run-1")
        #expect(report.durationSeconds == 7200)
        #expect(report.failedActions.first?.durationSeconds == 1800)
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
