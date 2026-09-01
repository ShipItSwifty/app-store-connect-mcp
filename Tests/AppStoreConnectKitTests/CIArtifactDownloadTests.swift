import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("CI artifact download + log analysis", .serialized)
struct CIArtifactDownloadTests {
    @Test("downloadArtifact returns bytes on a 2xx response")
    func downloadsBytes() async throws {
        let client = makeClient(responses: [
            .response(statusCode: 200, headers: [:], body: Data("hello logs".utf8))
        ])
        let data = try await client.downloadArtifact(from: "https://dl.example/logs.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hello logs")
    }

    @Test("downloadArtifact maps a non-2xx to ASCError.apiError")
    func downloadFailureStatus() async {
        let client = makeClient(responses: [.response(statusCode: 403, headers: [:], body: Data())])
        await #expect(throws: ASCError.self) {
            _ = try await client.downloadArtifact(from: "https://dl.example/expired")
        }
    }

    @Test("downloadArtifact rejects a non-http URL without a request")
    func downloadRejectsBadURL() async {
        let client = makeClient(responses: [])
        await #expect(throws: ASCError.self) {
            _ = try await client.downloadArtifact(from: "ftp://nope/logs")
        }
    }

    @Test("analyzeArtifactLog downloads then parses into findings")
    func analyzeArtifactLog() async throws {
        let log = "Sources/App/Foo.swift:10:5: error: cannot find 'bar' in scope\n** BUILD FAILED **"
        let client = makeClient(responses: [
            .response(statusCode: 200, headers: [:], body: Data(log.utf8))
        ])
        let analysis = try await client.analyzeArtifactLog(from: "https://dl.example/xcodebuild.log")
        #expect(analysis.findings.first?.kind == .compileError)
        #expect(analysis.findings.first?.line == 10)
    }

    @Test("analyzeArtifactLog throws for non-UTF-8 (binary) artifacts")
    func analyzeRejectsBinary() async {
        let client = makeClient(responses: [
            .response(statusCode: 200, headers: [:], body: Data([0xFF, 0xFE, 0x00, 0x01]))
        ])
        await #expect(throws: ASCError.self) {
            _ = try await client.analyzeArtifactLog(from: "https://dl.example/bundle.zip")
        }
    }

    @Test("looksLikeTextLog accepts .log/.txt and rejects xcresult/zip")
    func textLogHeuristic() {
        func artifact(type: String?, name: String?) -> CIFailureReport.FailedAction.Artifact {
            .init(fileType: type, fileName: name, downloadUrl: "https://x")
        }
        #expect(AppStoreConnectClient.looksLikeTextLog(artifact(type: "LOG", name: "xcodebuild.log")))
        #expect(AppStoreConnectClient.looksLikeTextLog(artifact(type: nil, name: "build.txt")))
        #expect(!AppStoreConnectClient.looksLikeTextLog(artifact(type: "XCRESULT", name: "Test.xcresult")))
        #expect(!AppStoreConnectClient.looksLikeTextLog(artifact(type: "LOG_BUNDLE", name: "logs.zip")))
        #expect(!AppStoreConnectClient.looksLikeTextLog(artifact(type: nil, name: "app.ipa")))
    }

    @Test("looksLikeLogBundle recognises LOG_BUNDLE and zipped logs, not xcresult")
    func logBundleHeuristic() {
        func artifact(type: String?, name: String?) -> CIFailureReport.FailedAction.Artifact {
            .init(fileType: type, fileName: name, downloadUrl: "https://x")
        }
        #expect(AppStoreConnectClient.looksLikeLogBundle(artifact(type: "LOG_BUNDLE", name: "logs.zip")))
        #expect(AppStoreConnectClient.looksLikeLogBundle(artifact(type: "LOG", name: "all-logs.zip")))
        #expect(!AppStoreConnectClient.looksLikeLogBundle(artifact(type: "LOG", name: "xcodebuild.log")))
        #expect(!AppStoreConnectClient.looksLikeLogBundle(artifact(type: "XCRESULT", name: "Test.xcresult")))
    }

    @Test("analyzeArtifactLog expands a zipped log bundle and merges findings from every text file")
    func analyzeArtifactLogExpandsBundle() async throws {
        let zip = try makeTestZip([
            "xcodebuild.log": "Sources/App/Foo.swift:10:5: error: cannot find 'bar' in scope\n",
            "scripts/ci_post_xcodebuild.sh.log": "+ ./upload.sh\nfatal error: signing identity not found\n",
            "products/App.ipa.bin": "binary-should-be-skipped",
        ])
        let client = makeClient(responses: [.response(statusCode: 200, headers: [:], body: zip)])

        let analysis = try await client.analyzeArtifactLog(from: "https://dl.example/all-logs.zip")
        let kinds = Set(analysis.findings.map(\.kind))
        #expect(kinds.contains(.compileError))
        #expect(analysis.findings.contains { $0.message.contains("signing identity not found") })
    }

    @Test("ciFailureReportWithLogs expands a LOG_BUNDLE artifact and captures script output")
    func failureReportExpandsLogBundle() async throws {
        let zip = try makeTestZip([
            "xcodebuild.log": "** BUILD SUCCEEDED **\n",
            "ci_post_xcodebuild.sh.log": "+ swiftlint --strict\n/src/A.swift:3:1: error: script phase failed\n",
        ])
        let client = makeClient(responses: [
            .json(["data": ["id": "run-1", "attributes": ["number": 1, "completionStatus": "FAILED"]]]),
            .json([
                "data": [
                    ["id": "act-1", "attributes": ["name": "Archive", "actionType": "ARCHIVE", "completionStatus": "FAILED"]]
                ]
            ]),
            .json(["data": [String]()]),
            .json(["data": [String]()]),
            .json([
                "data": [
                    [
                        "id": "ar-1",
                        "attributes": [
                            "fileType": "LOG_BUNDLE", "fileName": "logs.zip", "downloadUrl": "https://dl/logs.zip",
                        ],
                    ]
                ]
            ]),
            .response(statusCode: 200, headers: [:], body: zip),
        ])

        let result = try await client.ciFailureReportWithLogs(buildRunID: "run-1")
        let analysis = try #require(result.logFindingsByAction["act-1"])
        #expect(analysis.findings.contains { $0.message.contains("script phase failed") })
    }

    @Test("ciFailureReportWithLogs attaches parsed findings and notes skipped binaries")
    func failureReportWithLogs() async throws {
        let client = makeClient(responses: [
            // ciBuildRun
            .json(["data": ["id": "run-1", "attributes": ["number": 3, "completionStatus": "FAILED"]]]),
            // ciBuildActions
            .json([
                "data": [
                    ["id": "act-1", "attributes": ["name": "Build", "actionType": "BUILD", "completionStatus": "FAILED"]]
                ]
            ]),
            // issues for act-1
            .json(["data": [String]()]),
            // testResults for act-1
            .json(["data": [String]()]),
            // artifacts for act-1: one text log, one binary bundle
            .json([
                "data": [
                    ["id": "ar-1", "attributes": ["fileType": "LOG", "fileName": "xcodebuild.log", "downloadUrl": "https://dl/x.log"]],
                    ["id": "ar-2", "attributes": ["fileType": "LOG_BUNDLE", "fileName": "all.zip", "downloadUrl": "https://dl/all.zip"]],
                ]
            ]),
            // download of xcodebuild.log
            .response(
                statusCode: 200,
                headers: [:],
                body: Data("Sources/A.swift:2:1: error: boom\n".utf8)
            ),
        ])

        let result = try await client.ciFailureReportWithLogs(buildRunID: "run-1", workflowName: "Release")
        #expect(result.report.failedActions.count == 1)
        let analysis = try #require(result.logFindingsByAction["act-1"])
        #expect(analysis.findings.first?.kind == .compileError)
        #expect(result.skippedArtifacts.contains { $0.contains("all.zip") })
    }
}
