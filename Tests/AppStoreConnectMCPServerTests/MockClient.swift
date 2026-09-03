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
        /// Extra response headers merged on top of the default `Content-Type`.
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Canned] = []

    static func setResponses(_ responses: [Canned]) {
        lock.lock()
        defer { lock.unlock() }
        queue = responses
        lastBody = nil
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

    nonisolated(unsafe) private static var lastBody: Data?

    /// The JSON body of the most recent request, for the write tests — the write tools'
    /// whole job is the body they put on the wire.
    static func lastRequestBody() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = lastBody else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func record(body: Data?) {
        lock.lock()
        defer { lock.unlock() }
        lastBody = body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.record(body: request.bodyData)
        let canned = Self.next(for: request.url)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"].merging(canned.headers) { _, new in new }
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
        tokenProvider: { "test-token" },
        // One queued response per request; a retry would consume the next test's.
        retryPolicy: .disabled
    )
}

func jsonCanned(
    _ object: Any,
    statusCode: Int = 200,
    pathContains: String? = nil,
    headers: [String: String] = [:]
) -> MCPMockURLProtocol.Canned {
    .init(
        statusCode: statusCode,
        body: try! JSONSerialization.data(withJSONObject: object),
        pathContains: pathContains,
        headers: headers
    )
}

extension URLRequest {
    /// The request body, read from `httpBodyStream` when `URLSession` has already
    /// turned `httpBody` into a stream (which it does before a `URLProtocol` sees it).
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
