import Foundation
import Testing

@testable import AppStoreConnectKit

/// `getAll` walks `links.next` instead of silently returning one page.
@Suite("Pagination", .serialized)
struct PaginationTests {
    private func page(ids: [String], next: String?) -> MockHTTPResponse {
        var body: [String: Any] = ["data": ids.map { ["id": $0] }]
        if let next { body["links"] = ["next": next] }
        return .json(body)
    }

    @Test("Follows links.next until the collection is exhausted")
    func followsNextLink() async throws {
        let paths = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: paths,
            responses: [
                page(ids: ["a", "b"], next: "https://api.appstoreconnect.apple.com/v1/ciProducts?cursor=2"),
                page(ids: ["c"], next: nil),
            ]
        )

        let products: ASCListResponse<CIProduct> = try await client.getAll("/v1/ciProducts", limit: 100)
        #expect(products.data.map(\.id) == ["a", "b", "c"])
        #expect(paths.value.count == 2)
    }

    @Test("Stops at the requested limit even when more pages remain")
    func stopsAtLimit() async throws {
        let paths = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedPaths: paths,
            responses: [
                page(ids: ["a", "b", "c"], next: "https://api.appstoreconnect.apple.com/v1/ciProducts?cursor=2"),
                page(ids: ["d"], next: nil),
            ]
        )

        let products: ASCListResponse<CIProduct> = try await client.getAll("/v1/ciProducts", limit: 2)
        #expect(products.data.map(\.id) == ["a", "b"])
        // The cap is reached on the first page, so the second is never requested.
        #expect(paths.value.count == 1)
    }

    @Test("An empty next page ends the walk rather than looping")
    func emptyNextPageTerminates() async throws {
        let client = makeClient(responses: [
            page(ids: ["a"], next: "https://api.appstoreconnect.apple.com/v1/ciProducts?cursor=2"),
            page(ids: [], next: "https://api.appstoreconnect.apple.com/v1/ciProducts?cursor=3"),
        ])
        let products: ASCListResponse<CIProduct> = try await client.getAll("/v1/ciProducts", limit: 100)
        #expect(products.data.map(\.id) == ["a"])
    }

    @Test("A non-positive limit makes no request at all")
    func zeroLimitShortCircuits() async throws {
        let paths = LockedBox<[String]>([])
        let client = makeClientRecording(observedPaths: paths, responses: [])
        let products: ASCListResponse<CIProduct> = try await client.getAll("/v1/ciProducts", limit: 0)
        #expect(products.data.isEmpty)
        #expect(paths.value.isEmpty)
    }

    @Test("Page size is capped at the API maximum")
    func pageSizeIsCapped() async throws {
        let queries = LockedBox<[String]>([])
        let queue = ResponseQueue([page(ids: ["a"], next: nil)])
        let session = makeMockSession { request in
            queries.mutate { $0.append(request.url?.query ?? "") }
            return queue.next()
        }
        let client = AppStoreConnectClient(
            keyID: "KEY",
            issuerID: "ISSUER",
            privateKeyData: Data("placeholder".utf8),
            session: session,
            tokenProvider: { "test-token" }
        )

        let _: ASCListResponse<CIProduct> = try await client.getAll("/v1/ciProducts", limit: 5000)
        #expect(queries.value.first?.contains("limit=\(AppStoreConnectClient.maxPageSize)") == true)
    }

    @Test("ciIssues collects issues across pages")
    func ciIssuesPaginates() async throws {
        let client = makeClient(responses: [
            page(ids: ["issue-1"], next: "https://api.appstoreconnect.apple.com/v1/ciBuildActions/act-1/issues?cursor=2"),
            page(ids: ["issue-2"], next: nil),
        ])
        let issues = try await client.ciIssues(buildActionID: "act-1")
        #expect(issues.data.map(\.id) == ["issue-1", "issue-2"])
    }
}
