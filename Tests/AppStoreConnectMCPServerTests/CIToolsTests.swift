import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

@Suite("CITools (MCP)", .serialized)
struct CIToolsTests {
    private func text(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case .text(let value, _, _) = content { return value }
        }
        return ""
    }

    // MARK: - Catalog invariants

    @Test("Every tool has a unique name and a well-formed object schema")
    func catalogIsWellFormed() throws {
        let names = CITools.all.map(\.name)
        #expect(Set(names).count == names.count, "tool names must be unique")

        for tool in CITools.all {
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name): inputSchema is not an object")
                continue
            }
            #expect(schema["type"] == .string("object"))
            guard case .object(let properties)? = schema["properties"] else {
                Issue.record("\(tool.name): missing properties object")
                continue
            }
            if case .array(let required)? = schema["required"] {
                for entry in required {
                    guard case .string(let key) = entry else { continue }
                    #expect(properties[key] != nil, "\(tool.name): required '\(key)' is not a declared property")
                }
            }
            #expect(tool.description?.isEmpty == false)
        }
    }

    @Test("Catalog includes the new diagnostics tools")
    func catalogHasNewTools() {
        let names = Set(CITools.all.map(\.name))
        #expect(
            names.isSuperset(of: [
                "asc_ci_failure_report_with_logs",
                "asc_ci_analyze_log",
                "asc_submission_status",
                "asc_ci_list_test_plans",
            ]))
    }

    // MARK: - Dispatch

    @Test("Unknown tool name returns an error result, not a throw")
    func unknownTool() async throws {
        let result = try await CITools.call(name: "asc_does_not_exist", arguments: [:]) {
            makeMockMCPClient([])
        }
        #expect(result.isError == true)
        #expect(text(result).contains("Unknown tool"))
    }

    @Test("Missing required argument throws ASCError.invalidConfiguration")
    func missingRequiredArgument() async {
        await #expect(throws: ASCError.self) {
            _ = try await CITools.call(name: "asc_ci_list_workflows", arguments: [:]) {
                makeMockMCPClient([])
            }
        }
    }

    @Test("asc_ci_analyze_log parses inline text without needing a client")
    func analyzeLogInlineText() async throws {
        // The client provider throws — if the inline-text path touched it, the call would fail.
        let result = try await CITools.call(
            name: "asc_ci_analyze_log",
            arguments: ["text": .string("Sources/A.swift:3:1: error: boom")]
        ) {
            throw ASCError.invalidConfiguration(reason: "client must not be constructed for the inline-text path")
        }
        #expect(result.isError == false)
        #expect(text(result).contains("compileError"))
    }

    @Test("asc_ci_list_build_runs dispatches to the client and serializes the envelope")
    func listBuildRuns() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": [["id": "run-1", "attributes": ["number": 5, "completionStatus": "SUCCEEDED"]]]])
        ])
        let result = try await CITools.call(
            name: "asc_ci_list_build_runs",
            arguments: ["workflow_id": .string("wf-1"), "limit": .int(5)]
        ) { client }

        #expect(result.isError == false)
        let payload = text(result)
        #expect(payload.contains("run-1"))
        #expect(payload.contains("SUCCEEDED"))
    }

    @Test("asc_ci_list_products / list_workflows / get_issues / get_test_results / get_artifacts dispatch")
    func simpleGetTools() async throws {
        let cases: [(name: String, args: [String: Value], canned: [MCPMockURLProtocol.Canned], expect: String)] = [
            ("asc_ci_list_products", [:], [jsonCanned(["data": [["id": "prod-1", "attributes": ["name": "App"]]]])], "prod-1"),
            (
                "asc_ci_list_workflows", ["product_id": .string("p")],
                [jsonCanned(["data": [["id": "wf-1", "attributes": ["name": "Build"]]]])], "wf-1"
            ),
            (
                "asc_ci_get_issues", ["build_action_id": .string("a")],
                [jsonCanned(["data": [["id": "iss-1", "attributes": ["issueType": "ERROR", "message": "boom"]]]])], "boom"
            ),
            (
                "asc_ci_get_test_results", ["build_action_id": .string("a")],
                [jsonCanned(["data": [["id": "tr-1", "attributes": ["status": "FAILURE"]]]])], "FAILURE"
            ),
            (
                "asc_ci_get_artifacts", ["build_action_id": .string("a")],
                [jsonCanned(["data": [["id": "ar-1", "attributes": ["fileType": "LOG"]]]])], "LOG"
            ),
        ]
        for testCase in cases {
            let client = makeMockMCPClient(testCase.canned)
            let result = try await CITools.call(name: testCase.name, arguments: testCase.args) { client }
            #expect(result.isError == false, "\(testCase.name) should not error")
            #expect(text(result).contains(testCase.expect), "\(testCase.name) payload missing \(testCase.expect)")
        }
    }

    @Test("asc_ci_get_build_run merges run + actions into one payload")
    func getBuildRun() async throws {
        // `asc_ci_get_build_run` issues the run and actions requests concurrently
        // (`async let`), so pin the actions response to its endpoint rather than
        // relying on FIFO order.
        let client = makeMockMCPClient([
            jsonCanned(["data": ["id": "run-1", "attributes": ["number": 2, "completionStatus": "FAILED"]]]),
            jsonCanned(
                ["data": [["id": "act-1", "attributes": ["name": "Build", "completionStatus": "FAILED"]]]],
                pathContains: "/actions"
            ),
        ])
        let result = try await CITools.call(name: "asc_ci_get_build_run", arguments: ["build_run_id": .string("run-1")]) {
            client
        }
        #expect(result.isError == false)
        let payload = text(result)
        #expect(payload.contains("run-1"))
        #expect(payload.contains("act-1"))
    }

    @Test("asc_ci_failure_report aggregates a failed action")
    func failureReport() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": ["id": "run-1", "attributes": ["number": 1, "completionStatus": "FAILED"]]]),
            jsonCanned(["data": [["id": "act-1", "attributes": ["name": "Build", "actionType": "BUILD", "completionStatus": "FAILED"]]]]),
            jsonCanned(["data": [["id": "iss-1", "attributes": ["issueType": "ERROR", "message": "nope"]]]]),
            jsonCanned(["data": []]),
            jsonCanned(["data": []]),
        ])
        let result = try await CITools.call(name: "asc_ci_failure_report", arguments: ["build_run_id": .string("run-1")]) {
            client
        }
        #expect(result.isError == false)
        #expect(text(result).contains("nope"))
    }

    @Test("asc_ci_list_build_runs with failed_only returns only failed runs")
    func listBuildRunsFailedOnly() async throws {
        let client = makeMockMCPClient([
            jsonCanned([
                "data": [
                    ["id": "run-4", "attributes": ["number": 4, "completionStatus": "SUCCEEDED"]],
                    ["id": "run-3", "attributes": ["number": 3, "completionStatus": "FAILED"]],
                    ["id": "run-2", "attributes": ["number": 2, "completionStatus": "SUCCEEDED"]],
                    ["id": "run-1", "attributes": ["number": 1, "completionStatus": "ERRORED"]],
                ]
            ])
        ])
        let result = try await CITools.call(
            name: "asc_ci_list_build_runs",
            arguments: ["workflow_id": .string("wf-1"), "failed_only": .bool(true)]
        ) { client }

        #expect(result.isError == false)
        let payload = text(result)
        #expect(payload.contains("run-3"))
        #expect(payload.contains("run-1"))
        #expect(!payload.contains("run-4"))
        #expect(!payload.contains("run-2"))
    }

    @Test("asc_ci_list_test_plans flattens a workflow's TEST actions")
    func listTestPlans() async throws {
        let client = makeMockMCPClient([
            jsonCanned([
                "data": [
                    "id": "wf-1",
                    "attributes": [
                        "name": "Release",
                        "actions": [
                            ["name": "Build", "actionType": "BUILD"],
                            [
                                "name": "Test", "actionType": "TEST", "scheme": "AppScheme",
                                "testConfiguration": [
                                    "kind": "SPECIFIC_TEST_PLANS",
                                    "testPlans": [["name": "Smoke"]],
                                ],
                            ],
                        ],
                    ],
                ]
            ])
        ])
        let result = try await CITools.call(
            name: "asc_ci_list_test_plans", arguments: ["workflow_id": .string("wf-1")]
        ) { client }

        #expect(result.isError == false)
        let payload = text(result)
        #expect(payload.contains("SPECIFIC_TEST_PLANS"))
        #expect(payload.contains("\"Smoke\""))
    }

    @Test("A near-limit rate-limit header appends a heads-up content block")
    func rateLimitHint() async throws {
        let client = makeMockMCPClient([
            jsonCanned(
                ["data": [["id": "prod-1", "attributes": ["name": "App"]]]],
                headers: ["X-Rate-Limit": "user-hour-lim:1000;user-hour-rem:50"]
            )
        ])
        let result = try await CITools.call(name: "asc_ci_list_products", arguments: [:]) { client }

        #expect(result.isError == false)
        #expect(result.content.count == 2, "expected the payload plus a rate-limit hint block")
        #expect(text(result).contains("prod-1"))
        let joined = result.content.compactMap { content -> String? in
            if case .text(let value, _, _) = content { return value }
            return nil
        }.joined(separator: "\n")
        #expect(joined.contains("rate limit"))
        #expect(joined.contains("95%"))
    }

    @Test("A comfortable rate-limit header adds no extra block")
    func rateLimitNoHintWhenHealthy() async throws {
        let client = makeMockMCPClient([
            jsonCanned(
                ["data": [["id": "prod-1", "attributes": ["name": "App"]]]],
                headers: ["X-Rate-Limit": "user-hour-lim:1000;user-hour-rem:900"]
            )
        ])
        let result = try await CITools.call(name: "asc_ci_list_products", arguments: [:]) { client }
        #expect(result.content.count == 1)
    }

    @Test("asc_submission_status returns a diagnosis payload")
    func submissionStatus() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]]),
            jsonCanned(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0", "appStoreState": "METADATA_REJECTED"]]]]),
            jsonCanned(["data": []]),
        ])
        let result = try await CITools.call(
            name: "asc_submission_status",
            arguments: ["bundle_id": .string("com.example.app")]
        ) { client }

        #expect(result.isError == false)
        #expect(text(result).contains("METADATA_REJECTED"))
        #expect(text(result).lowercased().contains("metadata"))
    }
}
