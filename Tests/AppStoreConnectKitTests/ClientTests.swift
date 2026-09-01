import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("AppStoreConnectClient", .serialized)
struct ClientTests {
    @Test("Decodes a list response envelope")
    func decodesListResponse() async throws {
        let client = makeClient(responses: [
            .json([
                "data": [
                    ["id": "123", "attributes": ["bundleId": "com.example.app", "name": "Example"]]
                ]
            ])
        ])
        let apps: ASCListResponse<ASCApp> = try await client.get("/v1/apps")
        #expect(apps.data.count == 1)
        #expect(apps.data.first?.id == "123")
        #expect(apps.data.first?.attributes?.bundleId == "com.example.app")
    }

    @Test("Maps a non-2xx status to ASCError.apiError")
    func mapsErrorStatus() async throws {
        let client = makeClient(responses: [.error(statusCode: 403, body: "FORBIDDEN")])
        await #expect(throws: ASCError.self) {
            let _: ASCListResponse<ASCApp> = try await client.get("/v1/apps")
        }
    }

    @Test("Empty body decodes to NoContentResponse")
    func emptyBody() async throws {
        let client = makeClient(responses: [.empty(statusCode: 204)])
        let result: NoContentResponse = try await client.post("/v1/betaGroupsBuilds", body: ["data": [String]()])
        _ = result
    }
}
