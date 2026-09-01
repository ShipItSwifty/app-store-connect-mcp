import Foundation
import Testing

@testable import AppStoreConnectKit

/// Decode-from-fixture / re-encode round-trip coverage for the wire models.
///
/// Fixtures are camelCase because that is what App Store Connect actually sends,
/// and the client decodes with a plain `JSONDecoder` (no key strategy) to match.
@Suite("Model Codable")
struct ModelCodableTests {
    private var decoder: JSONDecoder { JSONDecoder() }

    @Test("ASCListResponse<ASCApp> decodes the data + links envelope")
    func decodesAppList() throws {
        let json = """
            {
              "data": [
                { "id": "1", "attributes": { "bundleId": "com.example.app", "name": "Example", "primaryLocale": "en-US" } }
              ],
              "links": { "self": "https://api/apps", "next": "https://api/apps?cursor=2" }
            }
            """
        let response = try decoder.decode(ASCListResponse<ASCApp>.self, from: Data(json.utf8))
        #expect(response.data.first?.attributes?.bundleId == "com.example.app")
        #expect(response.links?.next == "https://api/apps?cursor=2")
    }

    @Test("CIBuildRun decodes nested sourceCommit and survives an encode round-trip")
    func ciBuildRunRoundTrip() throws {
        let json = """
            {
              "id": "run-1",
              "attributes": {
                "number": 7,
                "executionProgress": "COMPLETE",
                "completionStatus": "FAILED",
                "sourceCommit": { "commitSha": "abc123", "message": "oops", "webUrl": "https://git/abc123" },
                "isPullRequestBuild": true
              }
            }
            """
        let run = try decoder.decode(CIBuildRun.self, from: Data(json.utf8))
        #expect(run.attributes?.number == 7)
        #expect(run.attributes?.sourceCommit?.commitSha == "abc123")
        #expect(run.attributes?.isPullRequestBuild == true)

        let reencoded = try JSONEncoder().encode(run)
        let again = try JSONDecoder().decode(CIBuildRun.self, from: reencoded)
        #expect(again.attributes?.sourceCommit?.message == "oops")
    }

    @Test("CIBuildAction decodes issueCounts")
    func ciBuildActionIssueCounts() throws {
        let json = """
            {
              "id": "act-1",
              "attributes": {
                "name": "Build",
                "actionType": "BUILD",
                "completionStatus": "FAILED",
                "issueCounts": { "errors": 2, "warnings": 5, "analyzerWarnings": 0, "testFailures": 0 }
              }
            }
            """
        let action = try decoder.decode(CIBuildAction.self, from: Data(json.utf8))
        #expect(action.attributes?.issueCounts?.errors == 2)
        #expect(action.attributes?.issueCounts?.warnings == 5)
    }

    @Test("CITestResult decodes destinationTestResults")
    func ciTestResultDestinations() throws {
        let json = """
            {
              "id": "test-1",
              "attributes": {
                "className": "MathTests",
                "name": "testAddition",
                "status": "FAILURE",
                "destinationTestResults": [
                  { "deviceName": "iPhone 15", "osVersion": "17.5", "status": "FAILURE", "duration": 0.12 }
                ]
              }
            }
            """
        let result = try decoder.decode(CITestResult.self, from: Data(json.utf8))
        #expect(result.attributes?.className == "MathTests")
        #expect(result.attributes?.destinationTestResults?.first?.deviceName == "iPhone 15")
        #expect(result.attributes?.destinationTestResults?.first?.duration == 0.12)
    }

    @Test("UploadReservation / UploadOperation / UploadHeader round-trip")
    func uploadModelsRoundTrip() throws {
        let reservation = UploadReservation(
            id: "res-1",
            operations: [
                UploadOperation(
                    method: "PUT",
                    url: "https://s3/part1",
                    offset: 0,
                    length: 1024,
                    requestHeaders: [UploadHeader(name: "Content-Type", value: "application/octet-stream")]
                )
            ]
        )
        let data = try JSONEncoder().encode(reservation)
        let decoded = try JSONDecoder().decode(UploadReservation.self, from: data)
        #expect(decoded.operations.first?.length == 1024)
        #expect(decoded.operations.first?.requestHeaders?.first?.name == "Content-Type")
    }

    @Test("UploadCommit round-trips and its memberwise init defaults uploaded to true")
    func uploadCommitRoundTrip() throws {
        #expect(UploadCommit(id: "r", checksum: "c").uploaded == true)
        let data = try JSONEncoder().encode(UploadCommit(id: "r", checksum: "c", uploaded: false))
        let decoded = try JSONDecoder().decode(UploadCommit.self, from: data)
        #expect(decoded.uploaded == false)
        #expect(decoded.checksum == "c")
    }

    @Test("CIArtifact decodes fileSize and downloadUrl")
    func ciArtifactDecode() throws {
        let json = """
            { "id": "a1", "attributes": { "fileType": "LOG_BUNDLE", "fileName": "logs.zip", "fileSize": 4096, "downloadUrl": "https://dl/logs" } }
            """
        let artifact = try decoder.decode(CIArtifact.self, from: Data(json.utf8))
        #expect(artifact.attributes?.fileSize == 4096)
        #expect(artifact.attributes?.downloadUrl == "https://dl/logs")
    }
}
