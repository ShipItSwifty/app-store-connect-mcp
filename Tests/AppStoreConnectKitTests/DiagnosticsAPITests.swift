import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the production-diagnostics endpoints and, above all, the normalization:
/// the raw payloads are far larger than any reader wants, so what gets *kept* is the
/// behaviour worth pinning.
@Suite("Diagnostics API")
struct DiagnosticsAPITests {
    // A two-thread stack: one frame is blamed, one is symbolicated but not blamed,
    // and one is an unsymbolicated system frame that should be dropped.
    private var logsPayload: [String: Any] {
        [
            "version": "1.0",
            "productData": [
                [
                    "signatureId": "sig-1",
                    "diagnosticLogs": [
                        [
                            "diagnosticMetaData": [
                                "appVersion": "1.4.0",
                                "buildVersion": "142",
                                "osVersion": "iPhone OS 18.2",
                                "deviceType": "iPhone14,3",
                                "event": "Hang",
                                "eventDetail": "2500ms",
                            ],
                            "callStackTree": [
                                [
                                    "callStackPerThread": true,
                                    "callStacks": [
                                        [
                                            "callStackRootFrames": [
                                                [
                                                    "binaryName": "MyApp",
                                                    "symbolName": "main",
                                                    "sampleCount": 10,
                                                    "subFrames": [
                                                        [
                                                            "binaryName": "MyApp",
                                                            "symbolName": "loadEverything()",
                                                            "fileName": "AppDelegate.swift",
                                                            "lineNumber": "42",
                                                            "sampleCount": 90,
                                                            "isBlameFrame": true,
                                                            "subFrames": [
                                                                ["binaryName": "libsystem", "address": "0x1"]
                                                            ],
                                                        ]
                                                    ],
                                                ]
                                            ]
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ],
                ]
            ],
        ]
    }

    @Test("diagnosticSignatures() filters by type and decodes the weight and insight")
    func signatures() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "sig-1",
                            "attributes": [
                                "diagnosticType": "HANGS",
                                "signature": "abc",
                                "weight": 12.5,
                                "insight": [
                                    "direction": "UP",
                                    "insightType": "REGRESSION",
                                    "referenceVersions": [["version": "1.3.0", "value": 3.0]],
                                ],
                            ],
                        ]
                    ]
                ])
            ]
        )

        let signatures = try await client.diagnosticSignatures(buildID: "b1", diagnosticType: "HANGS").data
        #expect(signatures.first?.attributes?.weight == 12.5)
        #expect(signatures.first?.attributes?.insight?.direction == "UP")
        #expect(signatures.first?.attributes?.insight?.referenceVersions?.first?.version == "1.3.0")
        #expect(observed.value[0].contains("/v1/builds/b1/diagnosticSignatures"))
        #expect(observed.value[0].contains("HANGS"))
    }

    @Test("diagnosticLogSummary() keeps the blamed frame and drops unsymbolicated noise")
    func logSummaryKeepsBlameFrames() async throws {
        let client = makeClient(responses: [.json(logsPayload)])

        let summary = try await client.diagnosticLogSummary(signatureID: "sig-1")
        #expect(summary.signatureID == "sig-1")

        let report = try #require(summary.reports.first)
        #expect(report.appVersion == "1.4.0")
        #expect(report.deviceType == "iPhone14,3")
        #expect(report.event == "Hang")
        // Every frame in the tree is counted, including the ones not kept, so a reader
        // can tell how much was elided.
        #expect(report.totalFrames == 3)

        // Once any frame is blamed, only blamed frames are worth showing.
        #expect(report.blameFrames.count == 1)
        let frame = try #require(report.blameFrames.first)
        #expect(frame.symbolName == "loadEverything()")
        #expect(frame.fileName == "AppDelegate.swift")
        #expect(frame.lineNumber == "42")
        #expect(frame.depth == 1)
    }

    @Test("With nothing blamed, the most-sampled symbolicated frames are kept instead")
    func logSummaryFallsBackToSampleCount() async throws {
        let client = makeClient(responses: [
            .json([
                "productData": [
                    [
                        "signatureId": "sig-2",
                        "diagnosticLogs": [
                            [
                                "diagnosticMetaData": ["appVersion": "1.4.0", "writesCaused": "512 MB"],
                                "callStackTree": [
                                    [
                                        "callStacks": [
                                            [
                                                "callStackRootFrames": [
                                                    ["symbolName": "low", "sampleCount": 1],
                                                    ["symbolName": "high", "sampleCount": 99],
                                                    ["address": "0x2"],
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
        ])

        let report = try #require(try await client.diagnosticLogSummary(signatureID: "sig-2").reports.first)
        #expect(report.writesCaused == "512 MB")
        #expect(report.blameFrames.map(\.symbolName) == ["high", "low"], "ranked by sample count, noise dropped")
        #expect(report.totalFrames == 3)
    }

    @Test("maxFramesPerReport caps what a huge report contributes")
    func logSummaryRespectsFrameCap() async throws {
        let frames = (0..<40).map { ["symbolName": "f\($0)", "sampleCount": $0] }
        let client = makeClient(responses: [
            .json([
                "productData": [
                    [
                        "signatureId": "sig-3",
                        "diagnosticLogs": [
                            ["callStackTree": [["callStacks": [["callStackRootFrames": frames]]]]]
                        ],
                    ]
                ]
            ])
        ])

        let report = try #require(
            try await client.diagnosticLogSummary(signatureID: "sig-3", maxFramesPerReport: 5).reports.first)
        #expect(report.blameFrames.count == 5)
        #expect(report.blameFrames.first?.symbolName == "f39", "highest sample count first")
        #expect(report.totalFrames == 40)
    }

    @Test("betaCrashLog() returns the log text, and nil when Apple has none yet")
    func betaCrashLog() async throws {
        let client = makeClient(responses: [
            .json(["data": ["id": "c1", "attributes": ["logText": "Thread 0 crashed"]]]),
            .json(["data": ["id": "c2", "attributes": ["logText": ""]]]),
        ])

        #expect(try await client.betaCrashLog(feedbackID: "f1") == "Thread 0 crashed")
        // An empty string means "not attached yet", which is not the same as a log.
        #expect(try await client.betaCrashLog(feedbackID: "f2") == nil)
    }

    @Test("perfPowerMetricsSummary() keeps regressions and the newest point of each series")
    func perfPowerMetrics() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "version": "1.0",
                    "insights": [
                        "regressions": [
                            [
                                "metric": "launchTime",
                                "metricCategory": "LAUNCH",
                                "summaryString": "50% slower than 1.3.0",
                                "highImpact": true,
                                "latestVersion": "1.4.0",
                                "populations": [
                                    ["device": "iPhone", "percentile": "P50", "deltaPercentage": 12.0],
                                    ["device": "iPhone", "percentile": "P90", "deltaPercentage": -55.0],
                                ],
                            ]
                        ]
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
                                            "unit": ["identifier": "ms", "displayName": "milliseconds"],
                                            "datasets": [
                                                [
                                                    "filterCriteria": [
                                                        "device": "iPhone14,3",
                                                        "deviceMarketingName": "iPhone 13 Pro",
                                                        "percentile": "P90",
                                                    ],
                                                    "points": [
                                                        ["version": "1.3.0", "value": 800.0, "goal": "GOOD"],
                                                        ["version": "1.4.0", "value": 1600.0, "goal": "POOR"],
                                                    ],
                                                ]
                                            ],
                                        ]
                                    ],
                                ]
                            ],
                        ]
                    ],
                ])
            ]
        )

        let summary = try await client.perfPowerMetricsSummary(appID: "123", platform: "IOS", metricType: "LAUNCH")
        let regression = try #require(summary.regressions.first)
        #expect(regression.summary == "50% slower than 1.3.0")
        #expect(regression.highImpact == true)
        // The worst-hit slice decides whether this is worth acting on, sign included.
        #expect(regression.worstDeltaPercentage == -55.0)

        let metric = try #require(summary.metrics.first)
        #expect(metric.version == "1.4.0", "newest point, not the whole series")
        #expect(metric.value == 1600.0)
        #expect(metric.goal == "POOR")
        #expect(metric.unit == "milliseconds")
        #expect(metric.device == "iPhone 13 Pro")
        #expect(metric.percentile == "P90")

        let sent = observed.value[0]
        #expect(sent.contains("/v1/apps/123/perfPowerMetrics"))
        #expect(sent.contains("LAUNCH"))
    }
}
