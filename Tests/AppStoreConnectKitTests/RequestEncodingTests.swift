import Foundation
import Testing

@testable import AppStoreConnectKit

/// Guards how requests go out on the wire.
///
/// The client used to encode bodies with `.convertToSnakeCase`, which silently broke
/// every write: App Store Connect expects `versionString`, not `version_string`, and
/// answers a malformed body by ignoring the attribute. Nothing in the suite inspected
/// an outgoing body, so it went unnoticed — these tests close that gap.
@Suite("Request encoding", .serialized)
struct RequestEncodingTests {
    @Test("Write bodies keep camelCase attribute keys")
    func writeBodiesAreCamelCase() async throws {
        let bodies = LockedBox<[[String: Any]]>([])
        let client = makeClientRecording(
            observedBodies: bodies,
            responses: [
                .json(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]]),  // app lookup
                .json(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]]),  // version lookup
                .json(["data": ["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]),  // PATCH releaseType
                .json(["data": ["id": "sub-1"]]),  // POST reviewSubmissions
            ]
        )

        _ = try await AppStoreReleaseService(client: client).submitForReview(
            bundleID: "com.example.app",
            automaticRelease: false,
            phasedRelease: false,
            resolveVersionString: { "1.0.0" }
        )

        let sent = bodies.value
        #expect(sent.count == 2)

        let patch = try #require(sent.first)
        let patchData = try #require(patch["data"] as? [String: Any])
        let attributes = try #require(patchData["attributes"] as? [String: Any])
        #expect(attributes["releaseType"] as? String == "MANUAL")
        #expect(attributes["release_type"] == nil)

        let post = try #require(sent.last)
        let postData = try #require(post["data"] as? [String: Any])
        let relationships = try #require(postData["relationships"] as? [String: Any])
        #expect(relationships["appStoreVersion"] != nil)
        #expect(relationships["app_store_version"] == nil)
    }

    @Test("Localization bodies send whatsNew, not whats_new")
    func localizationBodiesAreCamelCase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-\(UUID().uuidString)")
        let locale = directory.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Fixed a crash".write(to: locale.appendingPathComponent("release_notes.txt"), atomically: true, encoding: .utf8)

        let bodies = LockedBox<[[String: Any]]>([])
        let client = makeClientRecording(
            observedBodies: bodies,
            responses: [
                .json(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]]),  // app lookup
                .json(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]]),  // version lookup
                .json(["data": [["id": "info-1"]]]),  // appInfos
                .json(["data": []]),  // existing version localizations → none
                .json(["data": ["id": "loc-1"]]),  // POST appStoreVersionLocalizations
            ]
        )

        _ = try await AppStoreReleaseService(client: client).pushMetadata(
            bundleID: "com.example.app",
            directory: directory.path,
            resolveVersionString: { "1.0.0" }
        )

        let post = try #require(bodies.value.last)
        let data = try #require(post["data"] as? [String: Any])
        let attributes = try #require(data["attributes"] as? [String: Any])
        #expect(attributes["whatsNew"] as? String == "Fixed a crash")
        #expect(attributes["whats_new"] == nil)
    }

    @Test("Responses decode camelCase attributes as the live API sends them")
    func decodesCamelCaseResponses() async throws {
        let client = makeClient(responses: [
            .json(["data": [["id": "1", "attributes": ["bundleId": "com.example.app", "primaryLocale": "en-US"]]]])
        ])
        let apps: ASCListResponse<ASCApp> = try await client.get("/v1/apps")
        #expect(apps.data.first?.attributes?.bundleId == "com.example.app")
        #expect(apps.data.first?.attributes?.primaryLocale == "en-US")
    }
}
