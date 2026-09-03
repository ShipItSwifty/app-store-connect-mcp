import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the App Store / TestFlight half of the tool catalog: argument resolution,
/// the passthrough tool's path handling, and the read-only hints hosts rely on.
@Suite("AppStoreTools (MCP)", .serialized)
struct AppStoreToolsTests {
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

    // MARK: - Catalog

    @Test("Every tool advertises itself as read-only, since none of them write")
    func toolsAreAnnotatedReadOnly() {
        for tool in CITools.all {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) should be marked read-only")
            #expect(tool.annotations.destructiveHint == false)
        }
    }

    @Test("The App Store tools are part of the single advertised catalog")
    func appToolsAreAdvertised() {
        let names = Set(CITools.all.map(\.name))
        for expected in [
            "asc_list_apps", "asc_list_builds", "asc_testflight_build_status",
            "asc_list_beta_feedback", "asc_list_customer_reviews", "asc_api_get",
        ] {
            #expect(names.contains(expected))
        }
    }

    // MARK: - App resolution

    @Test("An app-scoped tool accepts a bundle id and resolves it to an app id")
    func resolvesBundleID() async throws {
        let result = try await call(
            "asc_list_builds",
            ["bundle_id": .string("com.example.app")],
            [
                jsonCanned(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]], pathContains: "/v1/apps"),
                jsonCanned(["data": [["id": "b1", "attributes": ["version": "142"]]]], pathContains: "/v1/builds"),
            ]
        )
        #expect(text(result).contains("\"version\" : \"142\""))
    }

    @Test("An app-scoped tool with neither app_id nor bundle_id says which argument is missing")
    func requiresAnAppIdentifier() async throws {
        await #expect(throws: ASCError.self) {
            _ = try await call("asc_list_beta_groups", [:], [])
        }
    }

    @Test("An unknown bundle id fails with a message naming it, not an empty list")
    func unknownBundleID() async throws {
        do {
            _ = try await call(
                "asc_list_customer_reviews",
                ["bundle_id": .string("com.nope")],
                [jsonCanned(["data": []], pathContains: "/v1/apps")]
            )
            Issue.record("expected a not-found error")
        } catch let error as ASCError {
            #expect(error.localizedDescription.contains("com.nope"))
        }
    }

    @Test("asc_list_beta_feedback rejects an unknown kind instead of silently querying crashes")
    func rejectsUnknownFeedbackKind() async throws {
        do {
            _ = try await call(
                "asc_list_beta_feedback",
                ["app_id": .string("123"), "kind": .string("video")],
                []
            )
            Issue.record("expected an invalid-configuration error")
        } catch let error as ASCError {
            #expect(error.localizedDescription.contains("video"))
        }
    }

    @Test("asc_testflight_build_status folds the build, its beta state, and its notes into one payload")
    func testFlightBuildStatus() async throws {
        let result = try await call(
            "asc_testflight_build_status",
            ["app_id": .string("123")],
            [
                jsonCanned(["data": [["id": "b1", "attributes": ["version": "142"]]]], pathContains: "/v1/builds?"),
                jsonCanned(
                    ["data": ["id": "d1", "attributes": ["externalBuildState": "WAITING_FOR_BETA_REVIEW"]]],
                    pathContains: "buildBetaDetail"
                ),
                jsonCanned(
                    ["data": [["id": "l1", "attributes": ["locale": "en-US", "whatsNew": "Fixed it."]]]],
                    pathContains: "betaBuildLocalizations"
                ),
            ]
        )
        let payload = text(result)
        #expect(payload.contains("WAITING_FOR_BETA_REVIEW"))
        #expect(payload.contains("Fixed it."))
        #expect(payload.contains("\"found\" : true"))
    }

    @Test("asc_testflight_build_status reports found:false rather than failing when there is no build")
    func testFlightBuildStatusWithNoBuilds() async throws {
        let result = try await call(
            "asc_testflight_build_status",
            ["app_id": .string("123")],
            [jsonCanned(["data": []], pathContains: "/v1/builds")]
        )
        #expect(text(result).contains("\"found\" : false"))
    }

    @Test("Each remaining App Store tool returns the resource it advertises")
    func remainingToolsReturnTheirResource() async throws {
        // One canned page per tool, asserting the payload the agent actually reads
        // back — the schema tests above only prove the handlers are reachable.
        let cases: [(name: String, arguments: [String: Value], response: Any, expected: String)] = [
            (
                "asc_list_apps", ["bundle_id": .string("com.example.app")],
                ["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app", "sku": "EX1"]]]], "EX1"
            ),
            (
                "asc_list_app_store_versions", ["app_id": .string("123")],
                ["data": [["id": "v1", "attributes": ["versionString": "1.4.0", "appVersionState": "REJECTED"]]]],
                "REJECTED"
            ),
            (
                "asc_get_version_metadata", ["version_id": .string("v1")],
                ["data": [["id": "l1", "attributes": ["locale": "en-US", "whatsNew": "Bug fixes."]]]], "Bug fixes."
            ),
            (
                "asc_list_beta_groups", ["app_id": .string("123")],
                ["data": [["id": "g1", "attributes": ["name": "QA", "publicLinkEnabled": false]]]], "QA"
            ),
            (
                "asc_list_beta_testers", ["beta_group_id": .string("g1")],
                ["data": [["id": "t1", "attributes": ["email": "a@b.c", "state": "INSTALLED"]]]], "INSTALLED"
            ),
            (
                "asc_list_beta_feedback", ["app_id": .string("123"), "kind": .string("screenshot")],
                ["data": [["id": "f1", "attributes": ["comment": "Layout broken"]]]], "Layout broken"
            ),
            (
                "asc_list_customer_reviews", ["app_id": .string("123"), "rating": .int(1)],
                ["data": [["id": "r1", "attributes": ["rating": 1, "body": "Crashes"]]]], "Crashes"
            ),
        ]

        for testCase in cases {
            let result = try await call(testCase.name, testCase.arguments, [jsonCanned(testCase.response)])
            #expect(text(result).contains(testCase.expected), "\(testCase.name) returned \(text(result))")
        }
    }

    @Test("asc_rate_limit_status reports the position parsed from Apple's header")
    func rateLimitStatus() async throws {
        let result = try await call(
            "asc_rate_limit_status",
            [:],
            [jsonCanned(["data": []], headers: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:700"])]
        )
        let payload = text(result)
        #expect(payload.contains("\"known\" : true"))
        #expect(payload.contains("3500"))
        #expect(payload.contains("700"))
    }

    @Test("asc_rate_limit_status says so rather than guessing when no header has been seen")
    func rateLimitStatusUnknown() async throws {
        let result = try await call("asc_rate_limit_status", [:], [jsonCanned(["data": []])])
        #expect(text(result).contains("\"known\" : false"))
    }

    // MARK: - Passthrough

    @Test("asc_api_get accepts a bare path, a full URL, and an inline query string")
    func parsesPaths() throws {
        let bare = try AppStoreTools.parseAPIPath("/v1/apps")
        #expect(bare.path == "/v1/apps")
        #expect(bare.query.isEmpty)

        // A `links.next` value can be pasted straight back in.
        let full = try AppStoreTools.parseAPIPath(
            "https://api.appstoreconnect.apple.com/v1/apps?limit=5&filter%5BbundleId%5D=com.example.app"
        )
        #expect(full.path == "/v1/apps")
        #expect(full.query["limit"] == "5")
        #expect(full.query["filter[bundleId]"] == "com.example.app")

        #expect(try AppStoreTools.parseAPIPath("  /v2/inAppPurchases  ").path == "/v2/inAppPurchases")
    }

    @Test("asc_api_get refuses anything that is not an App Store Connect API path")
    func rejectsForeignPaths() {
        for bad in ["https://evil.example.com/v1/apps", "/etc/passwd", "v1/apps", "/v3/apps"] {
            #expect(throws: ASCError.self) { _ = try AppStoreTools.parseAPIPath(bad) }
        }
    }

    @Test("asc_api_get's 'query' argument merges over the inline query string")
    func mergesQueryArgument() throws {
        let parsed = try AppStoreTools.parseQueryObject("{\"limit\":\"5\",\"include\":\"builds\",\"count\":3}")
        #expect(parsed["limit"] == "5")
        #expect(parsed["include"] == "builds")
        #expect(parsed["count"] == "3", "a JSON number is usable as a query value")
        #expect(try AppStoreTools.parseQueryObject(nil).isEmpty)
        #expect(throws: ASCError.self) { _ = try AppStoreTools.parseQueryObject("not json") }
    }

    @Test("asc_api_get returns Apple's JSON verbatim, including resources with no typed model")
    func passthroughReturnsRawJSON() async throws {
        let result = try await call(
            "asc_api_get",
            ["path": .string("/v1/apps/123/appPriceSchedule"), "query": .string("{\"include\":\"manualPrices\"}")],
            [jsonCanned(["data": ["id": "p1", "attributes": ["someFutureAttribute": true]]])]
        )
        #expect(text(result).contains("someFutureAttribute"))
        #expect(result.isError != true)
    }

    // MARK: - Argument handling

    @Test("A limit is clamped to a sane page walk instead of being passed through raw")
    func limitIsClamped() {
        let arguments = ToolArguments(["limit": .int(100_000), "zero": .int(0), "ok": .int(7)])
        #expect(arguments.int("limit", default: 20) == 200)
        #expect(arguments.int("zero", default: 20) == 1)
        #expect(arguments.int("ok", default: 20) == 7)
        #expect(arguments.int("absent", default: 20) == 20)
        #expect(arguments.int("limit", default: 1, max: 5) == 5)
    }
}
