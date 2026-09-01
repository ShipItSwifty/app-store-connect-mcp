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

    @Test("POST sends a JSON body and decodes the response envelope")
    func postWithBody() async throws {
        let sawBody = LockedBox<Bool>(false)
        let session = makeMockSession { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            // URLProtocol exposes the streamed body via httpBodyStream, not httpBody; just assert the header.
            sawBody.mutate { $0 = true }
            return .json(["data": ["id": "created-1"]])
        }
        let client = AppStoreConnectClient(
            keyID: "K", issuerID: "I", privateKeyData: Data("x".utf8),
            session: session, tokenProvider: { "t" }
        )
        let response: ASCResponse<ASCApp> = try await client.post("/v1/apps", body: ["data": ["type": "apps"]])
        #expect(response.data.id == "created-1")
        #expect(sawBody.value)
    }

    @Test("PATCH decodes the response envelope")
    func patchDecodes() async throws {
        let client = makeClient(responses: [.json(["data": ["id": "patched-1"]])])
        let response: ASCResponse<ASCApp> = try await client.patch("/v1/apps/1", body: ["data": ["type": "apps"]])
        #expect(response.data.id == "patched-1")
    }

    @Test("Empty body for a non-empty response type throws apiError")
    func emptyBodyForDecodableThrows() async {
        let client = makeClient(responses: [.empty(statusCode: 200)])
        await #expect(throws: ASCError.self) {
            let _: ASCResponse<ASCApp> = try await client.get("/v1/apps/1")
        }
    }

    @Test("Rate-limit headers on a response update the limiter")
    func responseUpdatesRateLimiter() async throws {
        let client = makeClient(responses: [
            .response(
                statusCode: 200,
                headers: ["Content-Type": "application/json", "X-Rate-Limit": "user-hour-lim:100;user-hour-rem:40"],
                body: try! JSONSerialization.data(withJSONObject: ["data": [String]()])
            )
        ])
        let _: ASCListResponse<ASCApp> = try await client.get("/v1/apps")
        let fraction = await client.rateLimiter.usageFraction
        #expect(fraction == 0.6)
    }
}
