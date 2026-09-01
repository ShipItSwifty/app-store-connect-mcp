import Foundation

@testable import AppStoreConnectKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal FIFO-queued `URLProtocol` mock for the MCP tool tests. Kept separate
/// from the `AppStoreConnectKitTests` mock because test targets don't share code.
final class MCPMockURLProtocol: URLProtocol {
    struct Canned: Sendable {
        let statusCode: Int
        let body: Data
        /// When set, this response is only served to a request whose URL contains
        /// this substring. Lets a test pin responses to endpoints when the code
        /// under test issues requests concurrently (e.g. `async let`), where plain
        /// FIFO ordering is racy.
        var pathContains: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Canned] = []

    static func setResponses(_ responses: [Canned]) {
        lock.lock()
        defer { lock.unlock() }
        queue = responses
    }

    private static func next(for url: URL?) -> Canned {
        lock.lock()
        defer { lock.unlock() }
        let path = url?.absoluteString ?? ""
        if let index = queue.firstIndex(where: { canned in
            guard let needle = canned.pathContains else { return false }
            return path.contains(needle)
        }) {
            return queue.remove(at: index)
        }
        // Fall back to FIFO for responses that don't pin a path.
        if let index = queue.firstIndex(where: { $0.pathContains == nil }) {
            return queue.remove(at: index)
        }
        return Canned(statusCode: 500, body: Data("no mock".utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let canned = Self.next(for: request.url)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func makeMockMCPClient(_ responses: [MCPMockURLProtocol.Canned]) -> AppStoreConnectClient {
    MCPMockURLProtocol.setResponses(responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MCPMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" }
    )
}

func jsonCanned(
    _ object: Any,
    statusCode: Int = 200,
    pathContains: String? = nil
) -> MCPMockURLProtocol.Canned {
    .init(
        statusCode: statusCode,
        body: try! JSONSerialization.data(withJSONObject: object),
        pathContains: pathContains
    )
}
