import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the review-readiness and signing-asset helpers: the 404-means-unset
/// relationships, the phased-release schedule, and the expiry triage.
@Suite("Review readiness and signing assets")
struct ReviewReadinessTests {
    @Test("phasedRelease() decodes the rollout and derives the share of users")
    func phasedRelease() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    "id": "pr1",
                    "attributes": [
                        "phasedReleaseState": "ACTIVE",
                        "currentDayNumber": 4,
                        "startDate": "2026-01-01T00:00:00Z",
                        "totalPauseDuration": 0,
                    ],
                ]
            ])
        ])

        let release = try #require(try await client.phasedRelease(versionID: "v1"))
        #expect(release.attributes?.phasedReleaseState == "ACTIVE")
        // Apple's schedule is fixed at 1/2/5/10/20/50/100 and isn't in the payload.
        #expect(release.percentageOfUsers == 10)
    }

    @Test("The phased-release schedule maps every day, and clamps past day 7")
    func phasedReleaseSchedule() {
        func percentage(day: Int?) -> Int? {
            ASCPhasedRelease(id: "p", attributes: .init(currentDayNumber: day)).percentageOfUsers
        }
        #expect((1...7).map { percentage(day: $0) } == [1, 2, 5, 10, 20, 50, 100])
        #expect(percentage(day: 9) == 100)
        #expect(percentage(day: 0) == nil)
        #expect(percentage(day: nil) == nil)
    }

    @Test("An unset to-one relationship reads as nil, not as an error")
    func unsetRelationshipsAreNil() async throws {
        // Apple answers "no phased release" and "no review detail" with a 404; a caller
        // asking whether one is configured should get an answer, not a thrown error.
        let client = makeClient(responses: [
            .error(statusCode: 404, body: #"{"errors":[{"status":"404","detail":"not found"}]}"#),
            .error(statusCode: 404, body: #"{"errors":[{"status":"404","detail":"not found"}]}"#),
        ])

        #expect(try await client.phasedRelease(versionID: "v1") == nil)
        #expect(try await client.appStoreReviewDetail(versionID: "v1") == nil)
    }

    @Test("A real failure on a to-one relationship still throws")
    func realFailuresStillThrow() async throws {
        let client = makeClient(responses: [.error(statusCode: 403, body: "forbidden")])
        await #expect(throws: ASCError.self) { _ = try await client.betaAppReviewDetail(appID: "123") }
    }

    @Test("Review details decode for both resources, without the demo password")
    func reviewDetails() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    "id": "rd1",
                    "attributes": [
                        "contactFirstName": "A",
                        "contactEmail": "a@b.c",
                        "demoAccountRequired": true,
                        "demoAccountName": "reviewer",
                        "demoAccountPassword": "hunter2",
                        "notes": "Tap the second tab.",
                    ],
                ]
            ])
        ])

        let detail = try #require(try await client.appStoreReviewDetail(versionID: "v1"))
        #expect(detail.attributes?.demoAccountRequired == true)
        #expect(detail.attributes?.notes == "Tap the second tab.")
        // The password is deliberately not modelled; encoding the detail must not carry it.
        let encoded = String(decoding: try JSONEncoder().encode(detail), as: UTF8.self)
        #expect(!encoded.contains("hunter2"))
    }

    @Test("appInfos() decodes the app-level state and age ratings")
    func appInfos() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    [
                        "id": "ai1",
                        "attributes": [
                            "state": "REJECTED",
                            "appStoreAgeRating": "FOUR_PLUS",
                            "kidsAgeBand": "SIX_TO_EIGHT",
                        ],
                    ]
                ]
            ])
        ])

        let info = try #require(try await client.appInfos(appID: "123").data.first)
        #expect(info.attributes?.state == "REJECTED")
        #expect(info.attributes?.appStoreAgeRating == "FOUR_PLUS")
    }

    @Test("signingAssets() flags expired, soon-to-expire, and INVALID assets")
    func signingAssets() async throws {
        let formatter = ISO8601DateFormatter()
        let expired = formatter.string(from: Date().addingTimeInterval(-2 * 86400))
        let soon = formatter.string(from: Date().addingTimeInterval(10 * 86400))
        let distant = formatter.string(from: Date().addingTimeInterval(300 * 86400))

        // `signingAssets` fetches both collections concurrently, so the responses have
        // to be pinned to their endpoints rather than queued.
        let client = makeClientRouting([
            (
                "/v1/certificates",
                .json([
                    "data": [
                        [
                            "id": "c1",
                            "attributes": [
                                "displayName": "Distribution", "expirationDate": expired,
                                "certificateType": "DISTRIBUTION",
                            ],
                        ],
                        ["id": "c2", "attributes": ["displayName": "Dev", "expirationDate": distant]],
                    ]
                ])
            ),
            (
                "/v1/profiles",
                .json([
                    "data": [
                        [
                            "id": "p1",
                            "attributes": [
                                "name": "App Store Profile", "expirationDate": soon, "profileState": "ACTIVE",
                            ],
                        ],
                        [
                            "id": "p2",
                            "attributes": [
                                "name": "Broken Profile", "expirationDate": distant, "profileState": "INVALID",
                            ],
                        ],
                    ]
                ])
            ),
        ])

        let report = try await client.signingAssets(withinDays: 30)
        #expect(report.certificates.count == 2)
        #expect(report.profiles.count == 2)

        // Already-expired first: the list is ordered by how urgent it is.
        #expect(report.expiringSoon.map(\.id) == ["c1", "p1"])
        #expect(report.expiringSoon[0].kind == "certificate")
        #expect((report.expiringSoon[0].daysRemaining ?? 0) < 0, "an expired asset reads as negative days")
        #expect(report.expiringSoon[1].daysRemaining == 9 || report.expiringSoon[1].daysRemaining == 10)

        // An INVALID profile breaks signing now, whatever its expiry says.
        #expect(report.invalidProfiles == ["Broken Profile"])
    }
}
