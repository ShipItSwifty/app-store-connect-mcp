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
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Canned] = []

    static func setResponses(_ responses: [Canned]) {
        lock.lock()
        defer { lock.unlock() }
        queue = responses
    }

    private static func next() -> Canned {
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? Canned(statusCode: 500, body: Data("no mock".utf8)) : queue.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let canned = Self.next()
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

func jsonCanned(_ object: Any, statusCode: Int = 200) -> MCPMockURLProtocol.Canned {
    .init(statusCode: statusCode, body: try! JSONSerialization.data(withJSONObject: object))
}
