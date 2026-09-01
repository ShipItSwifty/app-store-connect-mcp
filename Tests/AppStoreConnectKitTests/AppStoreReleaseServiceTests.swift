import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("AppStoreReleaseService", .serialized)
struct AppStoreReleaseServiceTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascmcp-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appResponse() -> MockHTTPResponse {
        .json(["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]])
    }

    // MARK: - pullMetadata

    @Test("pullMetadata writes name/subtitle/description/keywords/release_notes per locale")
    func pullMetadataWritesFiles() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = makeClient(responses: [
            appResponse(),
            // resolveLatestAppStoreVersion
            .json(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]]),
            // appInfoLocalizations
            .json([
                "data": [
                    ["id": "ail-en", "attributes": ["locale": "en-US", "name": "Example", "subtitle": "Best app"]]
                ]
            ]),
            // appStoreVersionLocalizations
            .json([
                "data": [
                    [
                        "id": "avl-en",
                        "attributes": [
                            "locale": "en-US", "description": "A description", "keywords": "a,b,c",
                            "whatsNew": "Bug fixes",
                        ],
                    ]
                ]
            ]),
        ])

        let result = try await AppStoreReleaseService(client: client)
            .pullMetadata(bundleID: "com.example.app", directory: dir.path)

        #expect(result.localesProcessed == 1)
        #expect(result.appID == "app-1")
        #expect(result.appStoreVersionID == "ver-1")

        let localeDir = dir.appendingPathComponent("en-US")
        #expect(try String(contentsOf: localeDir.appendingPathComponent("name.txt"), encoding: .utf8) == "Example")
        #expect(try String(contentsOf: localeDir.appendingPathComponent("keywords.txt"), encoding: .utf8) == "a,b,c")
        #expect(
            try String(contentsOf: localeDir.appendingPathComponent("release_notes.txt"), encoding: .utf8) == "Bug fixes"
        )
    }

    @Test("pullMetadata tolerates an app with no App Store version yet")
    func pullMetadataNoVersion() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = makeClient(responses: [
            appResponse(),
            .json(["data": [String]()]),  // no versions
            .json(["data": [["id": "ail-en", "attributes": ["locale": "en-US", "name": "Example"]]]]),
        ])

        let result = try await AppStoreReleaseService(client: client)
            .pullMetadata(bundleID: "com.example.app", directory: dir.path)
        #expect(result.localesProcessed == 1)
        #expect(result.appStoreVersionID == nil)
    }

    @Test("pullMetadata throws when the bundle id does not resolve")
    func pullMetadataAppNotFound() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = makeClient(responses: [.json(["data": [String]()])])
        await #expect(throws: ASCError.self) {
            _ = try await AppStoreReleaseService(client: client)
                .pullMetadata(bundleID: "com.example.missing", directory: dir.path)
        }
    }

    // MARK: - submitForReview

    @Test("submitForReview with manual release uses MANUAL releaseType and no phased release")
    func submitManual() async throws {
        let observedPaths = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: observedPaths,
            responses: [
                appResponse(),
                // resolveLatestAppStoreVersion -> existing
                .json(["data": [["id": "ver-9", "attributes": ["versionString": "3.0.0"]]]]),
                // PATCH appStoreVersions/ver-9
                .json(["data": ["id": "ver-9"]]),
                // POST reviewSubmissions
                .json(["data": ["id": "sub-42"]]),
            ])

        let result = try await AppStoreReleaseService(client: client).submitForReview(
            bundleID: "com.example.app",
            automaticRelease: false,
            phasedRelease: false,
            resolveVersionString: { "3.0.0" }
        )
        #expect(result.appStoreVersionID == "ver-9")
        #expect(result.reviewSubmissionID == "sub-42")
        #expect(observedPaths.value.contains("/v1/appStoreVersions/ver-9"))
        #expect(observedPaths.value.contains("/v1/reviewSubmissions"))
        #expect(!observedPaths.value.contains("/v1/appStoreVersionPhasedReleases"))
    }

    @Test("submitForReview with phased release also creates a phased-release schedule")
    func submitPhased() async throws {
        let observedPaths = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: observedPaths,
            responses: [
                appResponse(),
                .json(["data": [["id": "ver-9", "attributes": ["versionString": "3.1.0"]]]]),
                .json(["data": ["id": "ver-9"]]),  // PATCH
                .json(["data": ["id": "phased-1"]]),  // POST phased release
                .json(["data": ["id": "sub-99"]]),  // POST reviewSubmissions
            ])

        let result = try await AppStoreReleaseService(client: client).submitForReview(
            bundleID: "com.example.app",
            automaticRelease: true,
            phasedRelease: true,
            resolveVersionString: { "3.1.0" }
        )
        #expect(result.reviewSubmissionID == "sub-99")
        #expect(observedPaths.value.contains("/v1/appStoreVersionPhasedReleases"))
    }

    @Test("submitForReview creates a new App Store version when none exists")
    func submitCreatesVersion() async throws {
        let resolveCalled = LockedBox<Int>(0)
        let client = makeClient(responses: [
            appResponse(),
            .json(["data": [String]()]),  // no existing version
            .json(["data": ["id": "ver-new", "attributes": ["versionString": "4.0.0"]]]),  // POST create
            .json(["data": ["id": "ver-new"]]),  // PATCH
            .json(["data": ["id": "sub-new"]]),  // POST reviewSubmissions
        ])

        let result = try await AppStoreReleaseService(client: client).submitForReview(
            bundleID: "com.example.app",
            automaticRelease: false,
            phasedRelease: false,
            resolveVersionString: {
                resolveCalled.mutate { $0 += 1 }
                return "4.0.0"
            }
        )
        #expect(result.appStoreVersionID == "ver-new")
        #expect(resolveCalled.value == 1)
    }

    // MARK: - pushMetadata

    @Test("pushMetadata creates localizations from local files for each locale directory")
    func pushMetadataCreatesLocalizations() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let localeDir = dir.appendingPathComponent("en-US", isDirectory: true)
        try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        try "New Name".write(to: localeDir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try "New description".write(
            to: localeDir.appendingPathComponent("description.txt"), atomically: true, encoding: .utf8)

        let observedPaths = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: observedPaths,
            responses: [
                appResponse(),
                // resolveOrCreateAppStoreVersion -> existing
                .json(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]]),
                // resolveAppInfoID
                .json(["data": [["id": "info-1"]]]),
                // upsertAppInfoLocalization: GET existing by locale -> none
                .json(["data": [String]()]),
                // POST appInfoLocalizations
                .json(["data": ["id": "ail-new"]]),
                // upsertAppStoreVersionLocalization: GET existing -> none
                .json(["data": [String]()]),
                // POST appStoreVersionLocalizations
                .json(["data": ["id": "avl-new"]]),
            ])

        let result = try await AppStoreReleaseService(client: client).pushMetadata(
            bundleID: "com.example.app",
            directory: dir.path,
            resolveVersionString: { "1.0.0" }
        )
        #expect(result.localesProcessed == 1)
        // GET (filter[locale]) lives at /v1/apps/{id}/appInfoLocalizations; the create POST is the bare path.
        #expect(observedPaths.value.contains("/v1/appInfoLocalizations"))
        // Version localization GET + POST share the same path, so it appears twice.
        #expect(observedPaths.value.filter { $0 == "/v1/appStoreVersionLocalizations" }.count == 2)
    }

    @Test("pushMetadata updates an existing localization via PATCH")
    func pushMetadataUpdatesExisting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let localeDir = dir.appendingPathComponent("de-DE", isDirectory: true)
        try FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        try "Hallo".write(to: localeDir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)

        let observedMethods = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedMethods: observedMethods,
            responses: [
                appResponse(),
                .json(["data": [["id": "ver-1", "attributes": ["versionString": "1.0.0"]]]]),
                .json(["data": [["id": "info-1"]]]),
                // upsertAppInfoLocalization GET -> existing
                .json(["data": [["id": "ail-de", "attributes": ["locale": "de-DE", "name": "Alt"]]]]),
                // PATCH appInfoLocalizations/ail-de
                .json(["data": ["id": "ail-de"]]),
                // upsertAppStoreVersionLocalization GET -> none, and no description/keywords/whatsNew so it skips POST
            ])

        let result = try await AppStoreReleaseService(client: client).pushMetadata(
            bundleID: "com.example.app",
            directory: dir.path,
            resolveVersionString: { "1.0.0" }
        )
        #expect(result.localesProcessed == 1)
        #expect(observedMethods.value.contains("PATCH"))
    }
}
