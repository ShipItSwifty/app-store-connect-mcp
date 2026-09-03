import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the opt-in write tools: the gate itself, and the request bodies the
/// handlers put on the wire.
@Suite("WriteTools (MCP)", .serialized)
struct WriteToolsTests {
    private func text(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case .text(let value, _, _) = content { return value }
        }
        return ""
    }

    /// Invokes a write handler directly. Dispatch consults the catalog, which is built
    /// from the process environment, so a test cannot enable writes through it.
    private func callWrite(
        _ name: String,
        _ arguments: [String: Value],
        _ responses: [MCPMockURLProtocol.Canned]
    ) async throws -> CallTool.Result {
        let spec = try #require(WriteTools.specsByName[name])
        let client = makeMockMCPClient(responses)
        return try await spec.handler(ToolArguments(arguments), { client })
    }

    // MARK: - The gate

    @Test("Writes are off unless the environment opts in, and only for a truthy value")
    func gateReadsEnvironment() {
        #expect(!WriteTools.isEnabled([:]))
        #expect(!WriteTools.isEnabled(["ASC_ENABLE_WRITES": "0"]))
        #expect(!WriteTools.isEnabled(["ASC_ENABLE_WRITES": "false"]))
        #expect(!WriteTools.isEnabled(["ASC_ENABLE_WRITES": ""]))
        for truthy in ["1", "true", "TRUE", "yes"] {
            #expect(WriteTools.isEnabled(["ASC_ENABLE_WRITES": truthy]), "\(truthy) should enable writes")
        }
    }

    @Test("The default catalog is entirely read-only; enabling writes adds them")
    func catalogDependsOnTheGate() {
        let readOnly = CITools.specs(writesEnabled: false)
        let everySpecIsReadOnly = readOnly.allSatisfy(\.isReadOnly)
        #expect(everySpecIsReadOnly, "a default deployment advertises no write tools")
        #expect(!readOnly.map(\.name).contains("asc_submit_for_review"))

        let withWrites = CITools.specs(writesEnabled: true)
        #expect(withWrites.count == readOnly.count + WriteTools.specs.count)
        let writeNames = Set(WriteTools.specs.map(\.name))
        for spec in withWrites where writeNames.contains(spec.name) {
            #expect(!spec.isReadOnly)
            #expect(spec.tool.annotations.readOnlyHint == false)
            #expect(spec.tool.annotations.destructiveHint == true)
        }
        // Names must stay unique once both halves are concatenated.
        #expect(Set(withWrites.map(\.name)).count == withWrites.count)
    }

    @Test("Calling a disabled write tool explains how to enable it, not 'unknown tool'")
    func disabledWriteToolExplainsItself() async throws {
        // The suite runs without ASC_ENABLE_WRITES, so this is the real dispatch path.
        let result = try await CITools.dispatch(name: "asc_submit_for_review", arguments: [:]) {
            throw ASCError.invalidConfiguration(reason: "no client in this test")
        }
        #expect(result.isError == true)
        #expect(text(result).contains("ASC_ENABLE_WRITES"))
        #expect(!text(result).contains("Unknown tool"))

        let unknown = try await CITools.dispatch(name: "asc_not_a_tool", arguments: [:]) {
            throw ASCError.invalidConfiguration(reason: "no client in this test")
        }
        #expect(text(unknown).contains("Unknown tool"))
    }

    // MARK: - Handlers

    @Test("asc_ci_start_build posts the workflow relationship, and the git ref when given")
    func startBuild() async throws {
        let result = try await callWrite(
            "asc_ci_start_build",
            ["workflow_id": .string("wf-1"), "git_reference_id": .string("ref-1"), "clean": .bool(true)],
            [jsonCanned(["data": ["id": "run-1", "attributes": ["number": 42]]])]
        )
        #expect(text(result).contains("run-1"))

        let body = try #require(MCPMockURLProtocol.lastRequestBody())
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["type"] as? String == "ciBuildRuns")
        #expect((data["attributes"] as? [String: Any])?["clean"] as? Bool == true)
        let relationships = try #require(data["relationships"] as? [String: Any])
        let workflow = (relationships["workflow"] as? [String: Any])?["data"] as? [String: Any]
        #expect(workflow?["id"] as? String == "wf-1")
        let reference = (relationships["sourceBranchOrTag"] as? [String: Any])?["data"] as? [String: Any]
        #expect(reference?["type"] as? String == "scmGitReferences")
        // Apple rejects a null relationship rather than ignoring it.
        #expect(relationships["buildRun"] == nil)
    }

    @Test("asc_ci_rerun_build points at the previous run so the same commit is built")
    func rerunBuild() async throws {
        _ = try await callWrite(
            "asc_ci_rerun_build",
            ["build_run_id": .string("run-9")],
            [jsonCanned(["data": ["id": "run-10"]])]
        )

        let data = try #require(MCPMockURLProtocol.lastRequestBody()?["data"] as? [String: Any])
        let relationships = try #require(data["relationships"] as? [String: Any])
        let buildRun = (relationships["buildRun"] as? [String: Any])?["data"] as? [String: Any]
        #expect(buildRun?["id"] as? String == "run-9")
        #expect(relationships["workflow"] == nil)
        // `clean` was not asked for, so it must not be sent at all.
        #expect(data["attributes"] == nil)
    }

    @Test("asc_update_whats_new patches the existing localization for the locale")
    func updateWhatsNew() async throws {
        let result = try await callWrite(
            "asc_update_whats_new",
            ["bundle_id": .string("com.example.app"), "locale": .string("en-US"), "text": .string("Bug fixes.")],
            [
                jsonCanned(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]], pathContains: "/v1/apps?"),
                jsonCanned(["data": [["id": "v1", "attributes": ["versionString": "1.4.0"]]]], pathContains: "appStoreVersions"),
                jsonCanned(["data": [["id": "loc-1", "attributes": ["locale": "en-US"]]]], pathContains: "appStoreVersionLocalizations?"),
                jsonCanned(["data": ["id": "loc-1"]], pathContains: "appStoreVersionLocalizations/loc-1"),
            ]
        )
        #expect(text(result).contains("v1"))

        let data = try #require(MCPMockURLProtocol.lastRequestBody()?["data"] as? [String: Any])
        // camelCase on the wire, in both directions.
        #expect((data["attributes"] as? [String: Any])?["whatsNew"] as? String == "Bug fixes.")
    }

    @Test("asc_submit_for_review explains itself when there is no version and none was named")
    func submitWithoutVersion() async throws {
        do {
            _ = try await callWrite(
                "asc_submit_for_review",
                ["bundle_id": .string("com.example.app")],
                [
                    jsonCanned(["data": [["id": "app-1"]]], pathContains: "/v1/apps?"),
                    jsonCanned(["data": []], pathContains: "appStoreVersions"),
                ]
            )
            Issue.record("expected a configuration error")
        } catch let error as ASCError {
            #expect(error.localizedDescription.contains("version_string"))
        }
    }

    @Test("asc_create_analytics_report_request defaults to an ongoing subscription")
    func createAnalyticsRequest() async throws {
        _ = try await callWrite(
            "asc_create_analytics_report_request",
            ["app_id": .string("123")],
            [jsonCanned(["data": ["id": "req-1", "attributes": ["accessType": "ONGOING"]]])]
        )
        let data = try #require(MCPMockURLProtocol.lastRequestBody()?["data"] as? [String: Any])
        #expect((data["attributes"] as? [String: Any])?["accessType"] as? String == "ONGOING")
    }
}
