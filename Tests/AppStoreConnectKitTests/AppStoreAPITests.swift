import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the App Store / TestFlight read helpers: the filters and sort each one puts
/// on the wire, and that Apple's attribute shapes decode into the public models.
@Suite("App Store read API")
struct AppStoreAPITests {
    private func query(of url: String) -> [String: String] {
        guard let components = URLComponents(string: url) else { return [:] }
        return (components.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }

    @Test("apps() filters by bundle id and decodes the app record")
    func listApps() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "6740000001",
                            "attributes": [
                                "bundleId": "com.example.app",
                                "name": "Example",
                                "sku": "EXAMPLE1",
                                "primaryLocale": "en-US",
                            ],
                        ]
                    ]
                ])
            ]
        )

        let apps = try await client.apps(bundleID: "com.example.app", limit: 5)
        #expect(apps.data.first?.id == "6740000001")
        #expect(apps.data.first?.attributes?.sku == "EXAMPLE1")

        let sent = query(of: observed.value[0])
        #expect(sent["filter[bundleId]"] == "com.example.app")
        #expect(sent["limit"] == "5")
    }

    @Test("appStoreVersions() reads the state from whichever field the tenant populates")
    func appStoreVersions() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    ["id": "v1", "attributes": ["versionString": "1.4.0", "appVersionState": "REJECTED"]],
                    ["id": "v2", "attributes": ["versionString": "1.3.0", "appStoreState": "READY_FOR_SALE"]],
                ]
            ])
        ])

        let versions = try await client.appStoreVersions(appID: "123").data
        #expect(versions[0].state == "REJECTED")
        #expect(versions[1].state == "READY_FOR_SALE")
    }

    @Test("builds() goes through /v1/builds so it can sort, and carries every filter")
    func builds() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "b1",
                            "attributes": [
                                "version": "142",
                                "processingState": "VALID",
                                "buildAudienceType": "APP_STORE_ELIGIBLE",
                                "minOsVersion": "17.0",
                                "expirationDate": "2026-04-01T00:00:00Z",
                            ],
                        ]
                    ]
                ])
            ]
        )

        let builds = try await client.builds(
            appID: "123",
            version: "142",
            preReleaseVersion: "1.4.0",
            processingState: "VALID",
            limit: 10
        )
        #expect(builds.data.first?.attributes?.buildAudienceType == "APP_STORE_ELIGIBLE")
        // Export compliance unanswered decodes as nil rather than failing.
        #expect(builds.data.first?.attributes?.usesNonExemptEncryption == nil)

        // `/v1/apps/{id}/builds` rejects `sort`; the flat collection is used instead.
        #expect(observed.value[0].contains("/v1/builds"))
        let sent = query(of: observed.value[0])
        #expect(sent["filter[app]"] == "123")
        #expect(sent["sort"] == "-uploadedDate")
        #expect(sent["filter[version]"] == "142")
        #expect(sent["filter[preReleaseVersion.version]"] == "1.4.0")
        #expect(sent["filter[processingState]"] == "VALID")
    }

    @Test("betaGroups() decodes a public link, which Apple sends as a URL string")
    func betaGroups() async throws {
        // Modelled as `Bool` this threw `typeMismatch` for every group with a public
        // link enabled — the common case for an external group.
        let client = makeClient(responses: [
            .json([
                "data": [
                    [
                        "id": "g1",
                        "attributes": [
                            "name": "Public Beta",
                            "publicLink": "https://testflight.apple.com/join/abcd1234",
                            "publicLinkEnabled": true,
                            "publicLinkLimit": 5000,
                            "isInternalGroup": false,
                            "feedbackEnabled": true,
                        ],
                    ]
                ]
            ])
        ])

        let group = try await client.betaGroups(appID: "123").data.first
        #expect(group?.attributes?.publicLink == "https://testflight.apple.com/join/abcd1234")
        #expect(group?.attributes?.publicLinkLimit == 5000)
        #expect(group?.attributes?.feedbackEnabled == true)
    }

    @Test("buildBetaDetail() and betaBuildLocalizations() decode the TestFlight state")
    func testFlightState() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    "id": "d1",
                    "attributes": [
                        "internalBuildState": "READY_FOR_TESTING",
                        "externalBuildState": "WAITING_FOR_BETA_REVIEW",
                        "autoNotifyEnabled": true,
                    ],
                ]
            ]),
            .json(["data": [["id": "l1", "attributes": ["locale": "en-US", "whatsNew": "Fixed the crash."]]]]),
        ])

        let detail = try await client.buildBetaDetail(buildID: "b1").data
        #expect(detail.attributes?.externalBuildState == "WAITING_FOR_BETA_REVIEW")

        let notes = try await client.betaBuildLocalizations(buildID: "b1").data
        #expect(notes.first?.attributes?.whatsNew == "Fixed the crash.")
    }

    @Test("betaFeedback() targets the right collection per kind and sorts newest first")
    func betaFeedback() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "f1",
                            "attributes": [
                                "comment": "Crashes on launch",
                                "deviceModel": "iPhone14,3",
                                "osVersion": "18.2",
                                "batteryPercentage": 42,
                                "appUptimeInMilliseconds": 1200,
                                "createdDate": "2026-01-01T00:00:00Z",
                            ],
                        ]
                    ]
                ]),
                .json([
                    "data": [
                        [
                            "id": "s1",
                            "attributes": [
                                "comment": "Layout is broken here",
                                "screenshots": [["url": "https://example.com/a.png", "fileName": "a.png", "fileSize": 9]],
                            ],
                        ]
                    ]
                ]),
            ]
        )

        let crashes = try await client.betaFeedback(appID: "123", kind: .crash, buildID: "b1", limit: 10)
        #expect(crashes.data.first?.attributes?.batteryPercentage == 42)
        #expect(observed.value[0].contains("/v1/apps/123/betaFeedbackCrashSubmissions"))
        #expect(query(of: observed.value[0])["filter[build]"] == "b1")
        #expect(query(of: observed.value[0])["sort"] == "-createdDate")

        let shots = try await client.betaFeedback(appID: "123", kind: .screenshot, limit: 10)
        #expect(shots.data.first?.attributes?.screenshots?.first?.fileName == "a.png")
        #expect(observed.value[1].contains("/v1/apps/123/betaFeedbackScreenshotSubmissions"))
    }

    @Test("customerReviews() filters by rating and territory")
    func customerReviews() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        [
                            "id": "r1",
                            "attributes": [
                                "rating": 1,
                                "title": "Broken",
                                "body": "Crashes every time",
                                "reviewerNickname": "someone",
                                "territory": "USA",
                                "createdDate": "2026-01-01T00:00:00Z",
                            ],
                        ]
                    ]
                ])
            ]
        )

        let reviews = try await client.customerReviews(appID: "123", rating: 1, territory: "USA", limit: 25)
        #expect(reviews.data.first?.attributes?.rating == 1)

        let sent = query(of: observed.value[0])
        #expect(sent["filter[rating]"] == "1")
        #expect(sent["filter[territory]"] == "USA")
        #expect(sent["sort"] == "-createdDate")
    }

    @Test("getRaw() returns Apple's body untouched, including fields this package has no model for")
    func rawPassthrough() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [.json(["data": ["id": "x", "attributes": ["someFutureAttribute": true]]])]
        )

        let data = try await client.getRaw("/v1/appPriceSchedules/x", query: ["include": "manualPrices"])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let attributes = (object?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        #expect(attributes?["someFutureAttribute"] as? Bool == true)
        #expect(query(of: observed.value[0])["include"] == "manualPrices")
    }

    @Test("delete() issues DELETE and tolerates a 204 with no body")
    func deleteVerb() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedMethods: observed,
            responses: [.empty(statusCode: 204)]
        )

        try await client.delete("/v1/betaTesters/t1")
        #expect(observed.value == ["DELETE"])
    }
}
