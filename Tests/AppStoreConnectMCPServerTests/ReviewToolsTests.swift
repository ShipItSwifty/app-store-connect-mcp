import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the review-readiness tools: version resolution, the "not configured" answers,
/// and that the signing report reaches the agent with its warnings intact.
@Suite("ReviewTools (MCP)", .serialized)
struct ReviewToolsTests {
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

    @Test("The review tools are advertised in the one catalog, read-only")
    func advertised() {
        let byName = Dictionary(uniqueKeysWithValues: CITools.all.map { ($0.name, $0) })
        for expected in [
            "asc_phased_release_status", "asc_review_details", "asc_list_app_infos", "asc_signing_assets",
        ] {
            #expect(byName[expected]?.annotations.readOnlyHint == true, "\(expected) missing or not read-only")
        }
    }

    @Test("asc_phased_release_status resolves the newest version and derives the user share")
    func phasedRelease() async throws {
        let result = try await call(
            "asc_phased_release_status",
            ["bundle_id": .string("com.example.app")],
            [
                jsonCanned(["data": [["id": "app-1"]]], pathContains: "/v1/apps?"),
                jsonCanned(["data": [["id": "v1", "attributes": ["versionString": "1.4.0"]]]], pathContains: "appStoreVersions"),
                jsonCanned(
                    ["data": ["id": "pr1", "attributes": ["phasedReleaseState": "ACTIVE", "currentDayNumber": 5]]],
                    pathContains: "PhasedRelease"
                ),
            ]
        )
        let payload = text(result)
        #expect(payload.contains("ACTIVE"))
        #expect(payload.contains("\"percentageOfUsers\" : 20"))
    }

    @Test("asc_phased_release_status reports 'not configured' for an immediate release")
    func phasedReleaseAbsent() async throws {
        let result = try await call(
            "asc_phased_release_status",
            ["version_id": .string("v1")],
            [jsonCanned(["errors": [["detail": "not found"]]], statusCode: 404)]
        )
        #expect(text(result).contains("\"configured\" : false"))
        #expect(result.isError != true)
    }

    @Test("asc_review_details returns both review records and never the demo password")
    func reviewDetails() async throws {
        let result = try await call(
            "asc_review_details",
            ["app_id": .string("123"), "version_id": .string("v1")],
            [
                jsonCanned(
                    [
                        "data": [
                            "id": "rd1",
                            "attributes": [
                                "demoAccountRequired": true, "demoAccountName": "reviewer",
                                "demoAccountPassword": "hunter2", "notes": "Tap the second tab.",
                            ],
                        ]
                    ],
                    pathContains: "appStoreReviewDetail"
                ),
                jsonCanned(
                    ["data": ["id": "bd1", "attributes": ["contactEmail": "beta@example.com"]]],
                    pathContains: "betaAppReviewDetail"
                ),
            ]
        )
        let payload = text(result)
        #expect(payload.contains("Tap the second tab."))
        #expect(payload.contains("beta@example.com"))
        #expect(!payload.contains("hunter2"), "a credential must not reach the agent")
    }

    @Test("asc_signing_assets surfaces expiring and INVALID assets to the agent")
    func signingAssets() async throws {
        let expired = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        let result = try await call(
            "asc_signing_assets",
            ["within_days": .int(30)],
            [
                jsonCanned(
                    ["data": [["id": "c1", "attributes": ["displayName": "Distribution", "expirationDate": expired]]]],
                    pathContains: "/v1/certificates"
                ),
                jsonCanned(
                    ["data": [["id": "p1", "attributes": ["name": "Broken", "profileState": "INVALID"]]]],
                    pathContains: "/v1/profiles"
                ),
            ]
        )
        let payload = text(result)
        #expect(payload.contains("\"expiringSoon\""))
        #expect(payload.contains("Distribution"))
        #expect(payload.contains("Broken"))
    }

    @Test("asc_list_app_infos returns the app-level state that a version's state hides")
    func appInfos() async throws {
        let result = try await call(
            "asc_list_app_infos",
            ["app_id": .string("123")],
            [jsonCanned(["data": [["id": "ai1", "attributes": ["state": "REJECTED", "appStoreAgeRating": "FOUR_PLUS"]]]])]
        )
        #expect(text(result).contains("REJECTED"))
    }
}
