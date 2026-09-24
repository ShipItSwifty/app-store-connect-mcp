import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the diagnostics tools' argument resolution and the shape of what they hand back.
@Suite("DiagnosticsTools (MCP)", .serialized)
struct DiagnosticsToolsTests {
    private func text(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case .text(let value, _, _) = content { return value }
        }
        return ""
    }

    private func call(
        _ name: String,
        _ arguments: [String: Value],
        _ responses: [MCPMockURLProtocol.Canned]
    ) async throws -> CallTool.Result {
        let client = makeMockMCPClient(responses)
        return try await CITools.dispatch(name: name, arguments: arguments, makeClient: { client })
    }

    @Test("The diagnostics tools are advertised in the one catalog, read-only")
    func advertised() {
        let byName = Dictionary(uniqueKeysWithValues: CITools.all.map { ($0.name, $0) })
        for expected in [
            "asc_list_diagnostic_signatures", "asc_get_diagnostic_logs",
            "asc_get_beta_crash_log", "asc_perf_power_metrics",
        ] {
            #expect(byName[expected]?.annotations.readOnlyHint == true, "\(expected) missing or not read-only")
        }
    }

    @Test("asc_list_diagnostic_signatures falls back to the app's newest build")
    func resolvesNewestBuild() async throws {
        let result = try await call(
            "asc_list_diagnostic_signatures",
            ["bundle_id": .string("com.example.app"), "diagnostic_type": .string("HANGS")],
            [
                jsonCanned(["data": [["id": "app-1"]]], pathContains: "/v1/apps"),
                jsonCanned(["data": [["id": "b9", "attributes": ["version": "142"]]]], pathContains: "/v1/builds?"),
                jsonCanned(
                    ["data": [["id": "sig-1", "attributes": ["diagnosticType": "HANGS", "weight": 3.0]]]],
                    pathContains: "diagnosticSignatures"
                ),
            ]
        )
        #expect(text(result).contains("sig-1"))
    }

    @Test("asc_list_diagnostic_signatures says so when the app has no builds to look at")
    func noBuilds() async throws {
        do {
            _ = try await call(
                "asc_list_diagnostic_signatures",
                ["app_id": .string("123")],
                [jsonCanned(["data": []], pathContains: "/v1/builds")]
            )
            Issue.record("expected a not-found error")
        } catch let error as ASCError {
            #expect(error.localizedDescription.contains("no uploaded builds"))
        }
    }

    @Test("asc_get_diagnostic_logs returns blamed frames with file and line, not the raw tree")
    func diagnosticLogs() async throws {
        let result = try await call(
            "asc_get_diagnostic_logs",
            ["signature_id": .string("sig-1")],
            [
                jsonCanned([
                    "productData": [
                        [
                            "signatureId": "sig-1",
                            "diagnosticLogs": [
                                [
                                    "diagnosticMetaData": ["appVersion": "1.4.0", "event": "Hang"],
                                    "callStackTree": [
                                        [
                                            "callStacks": [
                                                [
                                                    "callStackRootFrames": [
                                                        [
                                                            "symbolName": "loadEverything()",
                                                            "fileName": "AppDelegate.swift",
                                                            "lineNumber": "42",
                                                            "isBlameFrame": true,
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ]
                ])
            ]
        )
        let payload = text(result)
        #expect(payload.contains("loadEverything()"))
        #expect(payload.contains("AppDelegate.swift"))
        #expect(payload.contains("\"totalFrames\" : 1"))
        // The raw tree keys must not leak through the normalization.
        #expect(!payload.contains("callStackRootFrames"))
    }

    @Test("asc_get_beta_crash_log distinguishes 'no log yet' from an error")
    func crashLog() async throws {
        let attached = try await call(
            "asc_get_beta_crash_log",
            ["feedback_id": .string("f1")],
            [jsonCanned(["data": ["id": "c1", "attributes": ["logText": "Thread 0 crashed"]]])]
        )
        #expect(text(attached).contains("Thread 0 crashed"))
        #expect(text(attached).contains("\"available\" : true"))

        let pending = try await call(
            "asc_get_beta_crash_log",
            ["feedback_id": .string("f2")],
            [jsonCanned(["data": ["id": "c2", "attributes": [:]]])]
        )
        #expect(text(pending).contains("\"available\" : false"))
        #expect(pending.isError != true, "a log Apple hasn't attached yet is not a failure")
    }

    @Test("asc_perf_power_metrics summarizes by default and passes the raw payload on request")
    func perfPowerMetrics() async throws {
        let payload: [String: Any] = [
            "insights": [
                "regressions": [["metric": "launchTime", "summaryString": "50% slower", "highImpact": true]]
            ],
            "productData": [
                [
                    "platform": "IOS",
                    "metricCategories": [
                        [
                            "identifier": "LAUNCH",
                            "metrics": [
                                [
                                    "identifier": "launchTime",
                                    "unit": ["displayName": "ms"],
                                    "datasets": [
                                        [
                                            "filterCriteria": ["percentile": "P90"],
                                            "points": [["version": "1.4.0", "value": 1600.0]],
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ],
                ]
            ],
        ]

        let summary = try await call(
            "asc_perf_power_metrics",
            ["app_id": .string("123"), "metric_type": .string("LAUNCH")],
            [jsonCanned(payload)]
        )
        #expect(text(summary).contains("50% slower"))
        #expect(text(summary).contains("\"regressions\""))
        #expect(!text(summary).contains("metricCategories"), "the reduced view drops Apple's nesting")

        let raw = try await call(
            "asc_perf_power_metrics",
            ["app_id": .string("123"), "raw": .bool(true)],
            [jsonCanned(payload)]
        )
        #expect(text(raw).contains("metricCategories"))
    }
}
