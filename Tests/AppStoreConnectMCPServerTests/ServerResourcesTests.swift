import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the resource catalog: that every resource reads through a real read-only
/// tool whose arguments its URI supplies, URI matching, and what a read returns.
@Suite("ServerResources", .serialized)
struct ServerResourcesTests {
    private let readOnlySpecs = Dictionary(
        uniqueKeysWithValues: CITools.specs(writesEnabled: false).map { ($0.name, $0) }
    )

    @Test("URIs and names are unique, and fixed resources and templates partition the specs")
    func catalogIsConsistent() {
        let uris = ServerResources.specs.map(\.uriTemplate)
        #expect(Set(uris).count == uris.count)
        let names = ServerResources.specs.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(ServerResources.resources.count + ServerResources.templates.count == ServerResources.specs.count)
        #expect(ServerResources.resources.allSatisfy { !$0.uri.contains("{") })
        #expect(ServerResources.templates.allSatisfy { $0.uriTemplate.contains("{") })
        #expect(ServerResources.specs.allSatisfy { $0.uriTemplate.hasPrefix("asc://") })
    }

    @Test("Every resource reads through a read-only tool, and its URI supplies that tool's arguments")
    func resourcesMapOntoReadOnlyTools() {
        for spec in ServerResources.specs {
            guard let tool = readOnlySpecs[spec.tool] else {
                Issue.record("\(spec.name) reads through \(spec.tool), which is not an advertised read-only tool")
                continue
            }
            let accepted = Set(tool.arguments.map(\.name))
            let required = Set(tool.arguments.filter(\.isRequired).map(\.name))
            let supplied = Set(spec.placeholders)
            #expect(supplied.isSubset(of: accepted), "\(spec.uriTemplate) binds arguments \(spec.tool) doesn't take")
            #expect(required.isSubset(of: supplied), "\(spec.uriTemplate) leaves required arguments of \(spec.tool) unbound")
        }
    }

    @Test("A URI binds its placeholders, percent-decoded, and nothing else matches")
    func matching() throws {
        let spec = try #require(ServerResources.specs.first { $0.name == "submission-status" })
        #expect(spec.match("asc://bundles/com.example.app/submission-status") == ["bundle_id": .string("com.example.app")])
        #expect(spec.match("asc://bundles/com.example%2Dapp/submission-status") == ["bundle_id": .string("com.example-app")])
        #expect(spec.match("asc://bundles//submission-status") == nil)
        #expect(spec.match("asc://bundles/com.example.app/testflight") == nil)
        #expect(spec.match("asc://bundles/com.example.app/submission-status/extra") == nil)

        let fixed = try #require(ServerResources.specs.first { $0.name == "apps" })
        #expect(fixed.match("asc://apps") == [:])
        #expect(fixed.match("asc://apps/123") == nil)
    }

    @Test("Reading a resource returns the tool's JSON under the requested URI")
    func readReturnsToolPayload() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": []], headers: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:700"])
        ])
        let result = try await ServerResources.read(uri: "asc://rate-limit") { client }

        let content = try #require(result.contents.first)
        #expect(result.contents.count == 1)
        #expect(content.uri == "asc://rate-limit")
        #expect(content.mimeType == "application/json")
        #expect(content.text?.contains("3500") == true)
    }

    @Test("A templated read passes the bound argument to the tool")
    func templatedReadPassesArguments() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": [["id": "b1", "attributes": ["version": "42"]]]], pathContains: "app-7")
        ])
        let result = try await ServerResources.read(uri: "asc://apps/app-7/builds") { client }
        #expect(result.contents.first?.text?.contains("b1") == true)
    }

    @Test("The rate-limit heads-up is not folded into a resource's contents")
    func headsUpIsDropped() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": []], headers: ["X-Rate-Limit": "user-hour-lim:1000;user-hour-rem:50"])
        ])
        let result = try await ServerResources.read(uri: "asc://rate-limit") { client }
        #expect(result.contents.count == 1)
        #expect(result.contents.first?.text?.contains("⚠️") == false)
    }

    @Test("An unknown URI is an invalid-params error")
    func unknownURI() async {
        await #expect(throws: MCPError.invalidParams("Unknown resource: asc://nope")) {
            _ = try await ServerResources.read(uri: "asc://nope") { makeMockMCPClient([]) }
        }
    }

    @Test("A failing read surfaces App Store Connect's message instead of an empty resource")
    func failingReadThrows() async {
        let client = makeMockMCPClient([.init(statusCode: 403, body: Data("forbidden for this role".utf8))])
        await #expect(throws: MCPError.self) {
            _ = try await ServerResources.read(uri: "asc://apps/app-1/ci/latest-failure") { client }
        }
    }
}
