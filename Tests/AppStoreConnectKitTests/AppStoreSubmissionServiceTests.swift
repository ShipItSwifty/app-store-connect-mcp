import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("AppStoreSubmissionService", .serialized)
struct AppStoreSubmissionServiceTests {
    private func appResponse() -> MockHTTPResponse {
        .json(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app", "name": "Example"]]]])
    }

    @Test("REJECTED version flags developer action and points at Resolution Center")
    func rejectedVersion() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [
                    ["id": "ver-1", "attributes": ["versionString": "1.2.0", "platform": "IOS", "appStoreState": "REJECTED"]]
                ]
            ]),
            .json([
                "data": [
                    [
                        "id": "sub-1",
                        "attributes": ["state": "UNRESOLVED_ISSUES", "platform": "IOS", "submittedDate": "2026-08-01T00:00:00Z"],
                    ]
                ]
            ]),
            .json(["data": [["id": "item-1", "attributes": ["state": "REJECTED"]]]]),
            .json(["data": ["id": "b1", "attributes": ["version": "100", "processingState": "VALID", "expired": false]]]),
        ])

        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.appID == "app-1")
        #expect(report.latestVersion?.state == "REJECTED")
        #expect(report.reviewSubmission?.state == "UNRESOLVED_ISSUES")
        #expect(report.items.first?.state == "REJECTED")
        #expect(report.needsDeveloperAction)
        #expect(report.diagnosis.contains("Resolution Center"))
        #expect(report.buildAttached == true)
        #expect(report.attachedBuild?.version == "100")
        #expect(report.attachedBuild?.processingState == "VALID")
        #expect(report.candidateBuild == nil)
    }

    @Test("Uses appVersionState when appStoreState is absent")
    func fallsBackToAppVersionState() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [["id": "ver-1", "attributes": ["versionString": "2.0.0", "appVersionState": "WAITING_FOR_REVIEW"]]]
            ]),
            .json(["data": [String]()]),
            .json(["data": NSNull()]),  // /v1/appStoreVersions/ver-1/build — nothing attached
            .json(["data": [String]()]),  // /v1/builds — no candidate build for the version
        ])
        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.latestVersion?.state == "WAITING_FOR_REVIEW")
        #expect(report.reviewSubmission == nil)
        #expect(report.items.isEmpty)
        #expect(!report.needsDeveloperAction)
        #expect(report.buildAttached == false)
        #expect(report.attachedBuild == nil)
        #expect(report.candidateBuild == nil)
    }

    @Test("Latest review submission is chosen by submittedDate, and a nil submittedDate counts as newest")
    func picksMostRecentSubmission() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [["id": "ver-1", "attributes": ["versionString": "1.0.0", "appStoreState": "IN_REVIEW"]]]
            ]),
            // Deliberately out of order; the in-progress one (no submittedDate) must win.
            .json([
                "data": [
                    ["id": "sub-old", "attributes": ["state": "COMPLETE", "submittedDate": "2026-01-01T00:00:00Z"]],
                    ["id": "sub-inprogress", "attributes": ["state": "READY_FOR_REVIEW"]],
                    ["id": "sub-mid", "attributes": ["state": "COMPLETE", "submittedDate": "2026-05-01T00:00:00Z"]],
                ]
            ]),
            .json(["data": [["id": "item-1", "attributes": ["state": "READY_FOR_REVIEW"]]]]),
            .json(["data": ["id": "b1", "attributes": ["version": "9", "processingState": "VALID", "expired": false]]]),
        ])
        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.reviewSubmission?.id == "sub-inprogress")
    }

    @Test("Among submitted submissions the newest submittedDate wins")
    func picksNewestSubmittedDate() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [["id": "ver-1", "attributes": ["versionString": "1.0.0", "appStoreState": "IN_REVIEW"]]]
            ]),
            .json([
                "data": [
                    ["id": "sub-old", "attributes": ["state": "COMPLETE", "submittedDate": "2026-01-01T00:00:00Z"]],
                    ["id": "sub-new", "attributes": ["state": "IN_REVIEW", "submittedDate": "2026-08-01T00:00:00Z"]],
                    ["id": "sub-mid", "attributes": ["state": "COMPLETE", "submittedDate": "2026-05-01T00:00:00Z"]],
                ]
            ]),
            .json(["data": [[String: String]]()]),
            .json(["data": ["id": "b1", "attributes": ["version": "9", "processingState": "VALID", "expired": false]]]),
        ])
        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.reviewSubmission?.id == "sub-new")
    }

    @Test("PREPARE_FOR_SUBMISSION with an INTERNAL_ONLY candidate build flags App Store ineligibility")
    func internalOnlyCandidateBuild() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [
                    [
                        "id": "ver-1",
                        "attributes": ["versionString": "1.0.0", "appStoreState": "PREPARE_FOR_SUBMISSION"],
                    ]
                ]
            ]),
            .json(["data": [[String: String]]()]),  // reviewSubmissions — none
            .json(["data": NSNull()]),  // /v1/appStoreVersions/ver-1/build — nothing attached
            .json([
                "data": [
                    [
                        "id": "b1",
                        "attributes": [
                            "version": "5", "processingState": "VALID", "expired": false,
                            "buildAudienceType": "INTERNAL_ONLY",
                        ],
                    ]
                ]
            ]),
        ])
        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.buildAttached == false)
        #expect(report.candidateBuild?.buildAudienceType == "INTERNAL_ONLY")
        #expect(report.candidateBuild?.audienceNote?.contains("INTERNAL_ONLY") == true)
        #expect(report.diagnosis.contains("buildAudienceType"))
        #expect(report.diagnosis.contains("INTERNAL_ONLY"))
        #expect(report.needsDeveloperAction)
    }

    @Test("An attached APP_STORE_ELIGIBLE build states its eligibility plainly")
    func attachedBuildAudienceNote() async throws {
        let client = makeClient(responses: [
            appResponse(),
            .json([
                "data": [["id": "ver-1", "attributes": ["versionString": "1.0.0", "appStoreState": "WAITING_FOR_REVIEW"]]]
            ]),
            .json(["data": [[String: String]]()]),
            .json([
                "data": [
                    "id": "b1",
                    "attributes": [
                        "version": "42", "processingState": "VALID", "expired": false,
                        "buildAudienceType": "APP_STORE_ELIGIBLE",
                    ],
                ]
            ]),
        ])
        let report = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.app")
        #expect(report.buildAttached == true)
        #expect(report.attachedBuild?.buildAudienceType == "APP_STORE_ELIGIBLE")
        #expect(report.attachedBuild?.audienceNote?.contains("APP_STORE_ELIGIBLE") == true)
    }

    @Test("Throws when the app cannot be resolved by bundle id")
    func appNotFound() async {
        let client = makeClient(responses: [.json(["data": [String]()])])
        await #expect(throws: ASCError.self) {
            _ = try await AppStoreSubmissionService(client: client).status(bundleID: "com.example.missing")
        }
    }

    // MARK: - Pure state interpretation

    @Test("needsDeveloperAction covers version state, submission state, and item state")
    func needsDeveloperActionMatrix() {
        let sut = AppStoreSubmissionService.self
        #expect(sut.needsDeveloperAction(versionState: "METADATA_REJECTED", submissionState: nil, itemStates: []))
        #expect(sut.needsDeveloperAction(versionState: nil, submissionState: "UNRESOLVED_ISSUES", itemStates: []))
        #expect(sut.needsDeveloperAction(versionState: nil, submissionState: nil, itemStates: ["APPROVED", "REJECTED"]))
        #expect(!sut.needsDeveloperAction(versionState: "IN_REVIEW", submissionState: "IN_REVIEW", itemStates: ["APPROVED"]))
    }

    @Test(
        "diagnose maps each notable state to guidance",
        arguments: [
            ("METADATA_REJECTED", "metadata"),
            ("INVALID_BINARY", "INVALID_BINARY"),
            ("DEVELOPER_REJECTED", "withdrawn"),
            ("PENDING_DEVELOPER_RELEASE", "release it manually"),
            ("IN_REVIEW", "wait for Apple"),
            ("WAITING_FOR_REVIEW", "queued"),
            ("PREPARE_FOR_SUBMISSION", "has not been submitted"),
        ]
    )
    func diagnoseMapping(state: String, expectedFragment: String) {
        let text = AppStoreSubmissionService.diagnose(
            versionString: "1.0.0",
            versionState: state,
            submissionState: nil,
            itemStates: []
        )
        #expect(text.localizedCaseInsensitiveContains(expectedFragment))
    }

    @Test("diagnose has a sensible default for unrecognized states")
    func diagnoseDefault() {
        let text = AppStoreSubmissionService.diagnose(
            versionString: nil,
            versionState: "SOME_FUTURE_STATE",
            submissionState: "SOMETHING",
            itemStates: ["ACCEPTED"]
        )
        #expect(text.contains("SOME_FUTURE_STATE"))
        #expect(text.contains("ACCEPTED"))
    }
}
