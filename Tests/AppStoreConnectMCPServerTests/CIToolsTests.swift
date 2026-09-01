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

    @Test("Every advertised tool is dispatchable")
    func everyToolDispatches() async throws {
        // The catalog and the dispatcher were once two hand-maintained lists, so a
        // tool could be advertised and then fall through to "Unknown tool". They are
        // now one list of `ToolSpec`s; this pins that invariant.
        for tool in CITools.all {
            // Called with no arguments and a provider that refuses to build a client,
            // every handler either throws (missing argument / no client) or returns —
            // both mean the name resolved. Only "Unknown tool" means it did not.
            do {
                let result = try await CITools.dispatch(name: tool.name, arguments: [:]) {
                    throw ASCError.invalidConfiguration(reason: "no client in this test")
                }
                #expect(!text(result).contains("Unknown tool"), "\(tool.name) is advertised but not dispatchable")
            } catch is ASCError {
                // Reached the handler, which is what this test asserts.
            }
        }
    }

    @Test("Generated schemas mark exactly the required arguments as required")
    func schemasMatchArgumentSpecs() throws {
        for spec in CITools.specs {
            guard case .object(let schema) = spec.tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else {
                Issue.record("\(spec.name): schema is not an object with properties")
                continue
            }
            #expect(properties.count == spec.arguments.count)

            var required: Set<String> = []
            if case .array(let entries)? = schema["required"] {
                for entry in entries {
                    if case .string(let key) = entry { required.insert(key) }
                }
            }
            #expect(required == Set(spec.arguments.filter(\.isRequired).map(\.name)))
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
                "asc_ci_latest_failure",
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

    @Test("asc_ci_latest_failure resolves a workflow, picks the newest red run, and reports it")
    func latestFailure() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": ["id": "wf-1", "attributes": ["name": "Build"]]], pathContains: "/ciWorkflows/wf-1"),
            jsonCanned(
                [
                    "data": [
                        [
                            "id": "run-9",
                            "attributes": [
                                "number": 9, "completionStatus": "FAILED",
                                "startedDate": "2026-02-01T10:00:00Z",
                            ],
                        ]
                    ]
                ],
                pathContains: "/buildRuns"
            ),
            jsonCanned(["data": ["id": "run-9", "attributes": ["number": 9, "completionStatus": "FAILED"]]]),
            jsonCanned(
                ["data": [["id": "act-1", "attributes": ["name": "Build", "actionType": "BUILD", "completionStatus": "FAILED"]]]],
                pathContains: "/actions"
            ),
            jsonCanned(
                ["data": [["id": "iss-1", "attributes": ["issueType": "ERROR", "message": "latest boom"]]]],
                pathContains: "/issues"
            ),
            jsonCanned(["data": []], pathContains: "/testResults"),
            jsonCanned(["data": []], pathContains: "/artifacts"),
        ])
        let result = try await CITools.call(
            name: "asc_ci_latest_failure", arguments: ["workflow_id": .string("wf-1")]
        ) { client }

        #expect(result.isError == false)
        let payload = text(result)
        #expect(payload.contains("\"found\" : true"))
        #expect(payload.contains("run-9"))
        #expect(payload.contains("latest boom"))
    }

    @Test("asc_ci_latest_failure returns found:false when the scope has no red runs")
    func latestFailureNone() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": ["id": "wf-1", "attributes": ["name": "Build"]]], pathContains: "/ciWorkflows/wf-1"),
            jsonCanned(
                ["data": [["id": "run-1", "attributes": ["number": 1, "completionStatus": "SUCCEEDED"]]]],
                pathContains: "/buildRuns"
            ),
        ])
        let result = try await CITools.call(
            name: "asc_ci_latest_failure", arguments: ["workflow_id": .string("wf-1")]
        ) { client }

        #expect(result.isError == false)
        #expect(text(result).contains("\"found\" : false"))
    }

    @Test("asc_ci_latest_failure without a scope throws ASCError.invalidConfiguration")
    func latestFailureNoScope() async {
        await #expect(throws: ASCError.self) {
            _ = try await CITools.call(name: "asc_ci_latest_failure", arguments: [:]) {
                makeMockMCPClient([])
            }
        }
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
            jsonCanned(
                ["data": ["id": "b1", "attributes": ["version": "42", "processingState": "VALID", "expired": false]]],
                pathContains: "ver-1/build"
            ),
        ])
        let result = try await CITools.call(
            name: "asc_submission_status",
            arguments: ["bundle_id": .string("com.example.app")]
        ) { client }

        #expect(result.isError == false)
        #expect(text(result).contains("METADATA_REJECTED"))
        #expect(text(result).lowercased().contains("metadata"))
        #expect(text(result).contains("\"buildAttached\" : true") || text(result).contains("\"buildAttached\":true"))
    }
}
