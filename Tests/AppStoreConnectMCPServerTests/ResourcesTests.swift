import Foundation
import MCP
import Testing

@testable import AppStoreConnectMCPServer

@Suite("MCP resources", .serialized)
struct ResourcesTests {
    @Test("Advertises the latest-failure resource template")
    func advertisesTemplate() {
        let template = MCPResources.templates.first
        #expect(template?.uriTemplate == "asc://apps/{bundle_id}/latest-failure")
        #expect(template?.mimeType == "application/json")
    }

    @Test("Reads the latest failure report by bundle id")
    func readsLatestFailure() async throws {
        let client = makeMockMCPClient([
            jsonCanned(
                ["data": [["id": "app-1", "attributes": ["bundleId": "com.example.app"]]]],
                pathContains: "/v1/apps"
            ),
            jsonCanned(["data": []], pathContains: "/ciProducts"),
        ])
        let result = try await MCPResources.read(
            uri: "asc://apps/com.example.app/latest-failure",
            makeClient: { client }
        )
        #expect(result.contents.count == 1)
        #expect(result.contents.first?.text?.contains("found") == true)
        #expect(result.contents.first?.text?.contains("false") == true)
    }
}
