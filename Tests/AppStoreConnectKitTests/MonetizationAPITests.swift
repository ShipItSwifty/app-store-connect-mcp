import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the in-app purchase, subscription, finance-report, and review-reply and
/// TestFlight-membership additions: the endpoints and filters they send, and the
/// shapes they decode.
@Suite("Monetization, finance, and engagement API", .serialized)
struct MonetizationAPITests {
    private func query(of url: String) -> [String: String] {
        guard let components = URLComponents(string: url) else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }

    @Test("inAppPurchases() hits the v2 collection and sends its filters")
    func inAppPurchasesFilters() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "iap-1",
                            "attributes": [
                                "name": "100 Coins", "productId": "coins100", "inAppPurchaseType": "CONSUMABLE",
                                "state": "APPROVED", "familySharable": false, "contentHosting": false,
                            ],
                        ]
                    ]
                ])
            ]
        )

        let purchases = try await client.inAppPurchases(appID: "123", type: "CONSUMABLE", state: "APPROVED")
        let attributes = try #require(purchases.data.first?.attributes)
        #expect(attributes.productId == "coins100")
        #expect(attributes.familySharable == false)

        #expect(observed.value[0].contains("/v1/apps/123/inAppPurchasesV2"))
        let sent = query(of: observed.value[0])
        #expect(sent["filter[inAppPurchaseType]"] == "CONSUMABLE")
        #expect(sent["filter[state]"] == "APPROVED")
    }

    @Test("subscriptionCatalog() lists each group with its subscriptions, highest level first")
    func subscriptionCatalogOrdersByLevel() async throws {
        let client = makeClientRouting([
            (
                "/v1/apps/123/subscriptionGroups",
                .json([
                    "data": [
                        ["id": "grp-pro", "attributes": ["referenceName": "Pro"]],
                        ["id": "grp-empty", "attributes": ["referenceName": "Legacy"]],
                    ]
                ])
            ),
            (
                "/v1/subscriptionGroups/grp-pro/subscriptions",
                .json([
                    "data": [
                        ["id": "s-unranked", "attributes": ["productId": "pro.trial"]],
                        [
                            "id": "s-month",
                            "attributes": ["productId": "pro.monthly", "groupLevel": 2, "subscriptionPeriod": "ONE_MONTH"],
                        ],
                        [
                            "id": "s-year",
                            "attributes": ["productId": "pro.yearly", "groupLevel": 1, "subscriptionPeriod": "ONE_YEAR"],
                        ],
                    ]
                ])
            ),
            ("/v1/subscriptionGroups/grp-empty/subscriptions", .json(["data": [String]()])),
        ])

        let catalog = try await client.subscriptionCatalog(appID: "123")
        #expect(catalog.map(\.group.id) == ["grp-pro", "grp-empty"])
        #expect(catalog[0].subscriptions.map(\.id) == ["s-year", "s-month", "s-unranked"])
        #expect(catalog[0].subscriptions[0].attributes?.subscriptionPeriod == "ONE_YEAR")
        #expect(catalog[1].subscriptions.isEmpty)
    }

    @Test(
        "financeReport() defaults the region to the all-regions code for its report type",
        arguments: [("FINANCIAL", "ZZ"), ("FINANCE_DETAIL", "Z1")]
    )
    func financeReportRegionDefault(reportType: String, expectedRegion: String) async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [.response(statusCode: 200, headers: [:], body: Data("Region\tUnits\nUS\t3\n".utf8))]
        )

        let table = try await client.financeReport(vendorNumber: "8001", reportDate: "2026-09", reportType: reportType)
        #expect(table?.rows.count == 1)

        #expect(observed.value[0].contains("/v1/financeReports"))
        let sent = query(of: observed.value[0])
        #expect(sent["filter[regionCode]"] == expectedRegion)
        #expect(sent["filter[reportType]"] == reportType)
        #expect(sent["filter[reportDate]"] == "2026-09")
        #expect(sent["filter[vendorNumber]"] == "8001")
    }

    @Test("financeReport() keeps an explicit region and reads a 404 as no report")
    func financeReportExplicitRegionAndMissing() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [.error(statusCode: 404, body: "{\"errors\":[]}")]
        )

        let table = try await client.financeReport(vendorNumber: "8001", reportDate: "2026-10", regionCode: "EU")
        #expect(table == nil)
        #expect(query(of: observed.value[0])["filter[regionCode]"] == "EU")
    }

    @Test("financeReport() still surfaces a 403 rather than reading it as no report")
    func financeReportForbidden() async {
        let client = makeClient(responses: [.error(statusCode: 403, body: "FORBIDDEN")])
        await #expect(throws: ASCError.self) {
            _ = try await client.financeReport(vendorNumber: "8001", reportDate: "2026-09")
        }
    }

    @Test("addBuilds(_:toBetaGroup:) rejects an empty build list without a request")
    func addBuildsNeedsBuilds() async {
        let client = makeClient(responses: [])
        await #expect(throws: ASCError.self) {
            try await client.addBuilds([], toBetaGroup: "grp-1")
        }
    }

    @Test("inviteBetaTester() rejects an empty group list without a request")
    func inviteNeedsGroups() async {
        let client = makeClient(responses: [])
        await #expect(throws: ASCError.self) {
            _ = try await client.inviteBetaTester(email: "a@example.com", betaGroupIDs: [])
        }
    }

    @Test("addBuilds(_:toBetaGroup:) posts every build to the group's relationship")
    func addBuildsPostsLinkages() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(observedPaths: observed, responses: [.empty(statusCode: 204)])
        try await client.addBuilds(["b1", "b2"], toBetaGroup: "grp-1")
        #expect(observed.value == ["/v1/betaGroups/grp-1/relationships/builds"])
    }
}
