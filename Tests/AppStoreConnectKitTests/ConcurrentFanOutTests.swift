import Foundation
import Testing

@testable import AppStoreConnectKit

/// The aggregating helpers fan their requests out concurrently; these pin down that the
/// results still come back in Apple's order and that the concurrency stays bounded.
@Suite("Concurrent fan-out")
struct ConcurrentFanOutTests {
    @Test("concurrentMap keeps input order even when later items finish first")
    func preservesOrder() async throws {
        let delays = [30, 5, 20, 1, 10]
        let mapped = try await delays.concurrentMap(maxConcurrency: 5) { delay in
            try await Task.sleep(for: .milliseconds(delay))
            return delay
        }
        #expect(mapped == delays)
    }

    @Test("concurrentMap never exceeds its concurrency limit")
    func boundsConcurrency() async throws {
        let inFlight = LockedBox((current: 0, peak: 0))
        _ = try await Array(0..<12).concurrentMap(maxConcurrency: 3) { value in
            inFlight.mutate { state in
                state.current += 1
                state.peak = max(state.peak, state.current)
            }
            try await Task.sleep(for: .milliseconds(5))
            inFlight.mutate { $0.current -= 1 }
            return value
        }
        #expect(inFlight.value.peak <= 3)
        #expect(inFlight.value.peak > 1)
    }

    @Test("concurrentMap rethrows the first failure")
    func propagatesFailure() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await [1, 2, 3].concurrentMap { value in
                if value == 2 { throw Boom() }
                return value
            }
        }
    }

    @Test("concurrentMap on an empty sequence makes no calls")
    func emptyInput() async throws {
        let mapped = try await [Int]().concurrentMap { $0 }
        #expect(mapped.isEmpty)
    }

    @Test("Failure report keeps several failed actions in Apple's order")
    func failureReportOrdersActions() async throws {
        let client = makeClientRouting([
            (
                "/ciBuildRuns/run-2/actions",
                .json([
                    "data": [
                        ["id": "act-a", "attributes": ["name": "Build", "actionType": "BUILD", "completionStatus": "FAILED"]],
                        ["id": "act-ok", "attributes": ["name": "Lint", "actionType": "BUILD", "completionStatus": "SUCCEEDED"]],
                        ["id": "act-b", "attributes": ["name": "Test", "actionType": "TEST", "completionStatus": "ERRORED"]],
                        ["id": "act-c", "attributes": ["name": "Archive", "actionType": "ARCHIVE", "completionStatus": "FAILED"]],
                    ]
                ])
            ),
            ("/ciBuildRuns/run-2", .json(["data": ["id": "run-2", "attributes": ["number": 2, "completionStatus": "FAILED"]]])),
            (
                "/ciBuildActions/act-b/issues",
                .json(["data": [["id": "iss-b", "attributes": ["issueType": "ERROR", "message": "from b"]]]])
            ),
            ("/issues", .json(["data": [String]()])),
            ("/testResults", .json(["data": [String]()])),
            ("/artifacts", .json(["data": [String]()])),
        ])

        let report = try await client.ciFailureReport(buildRunID: "run-2")
        #expect(report.failedActions.map(\.id) == ["act-a", "act-b", "act-c"])
        #expect(report.failedActions[1].issues.first?.message == "from b")
        #expect(report.failedActions[0].issues.isEmpty)
    }

    @Test("Latest failure across several products picks the newest red run")
    func latestFailureAcrossProducts() async throws {
        let client = makeClientRouting([
            (
                "/v1/ciProducts?",
                .json([
                    "data": [
                        ["id": "prod-1", "attributes": ["name": "App"]],
                        ["id": "prod-2", "attributes": ["name": "Widget"]],
                    ]
                ])
            ),
            ("/ciProducts/prod-1/workflows", .json(["data": [["id": "wf-old", "attributes": ["name": "Nightly"]]]])),
            ("/ciProducts/prod-2/workflows", .json(["data": [["id": "wf-new", "attributes": ["name": "PR"]]]])),
            (
                "/ciWorkflows/wf-old/buildRuns",
                .json([
                    "data": [
                        [
                            "id": "run-old",
                            "attributes": [
                                "number": 1, "completionStatus": "FAILED", "startedDate": "2026-01-01T00:00:00Z",
                            ],
                        ]
                    ]
                ])
            ),
            (
                "/ciWorkflows/wf-new/buildRuns",
                .json([
                    "data": [
                        [
                            "id": "run-new",
                            "attributes": [
                                "number": 2, "completionStatus": "FAILED", "startedDate": "2026-03-01T00:00:00Z",
                            ],
                        ]
                    ]
                ])
            ),
            ("/ciBuildRuns/run-new/actions", .json(["data": [String]()])),
            ("/ciBuildRuns/run-new", .json(["data": ["id": "run-new", "attributes": ["number": 2]]])),
        ])

        let latest = try await client.ciLatestFailureReport(appID: "app-1")
        #expect(latest.found)
        #expect(latest.workflowsScanned == 2)
        #expect(latest.buildRunID == "run-new")
        #expect(latest.workflowName == "PR")
    }
}
