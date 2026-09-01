import Foundation

@testable import AppStoreConnectKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A canned HTTP response for `MockURLProtocol`.
enum MockHTTPResponse: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data)

    static func json(_ object: Any, statusCode: Int = 200) -> MockHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return .response(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data)
    }

    static func empty(statusCode: Int = 200) -> MockHTTPResponse {
        .response(statusCode: statusCode, headers: [:], body: Data())
    }

    static func error(statusCode: Int, body: String) -> MockHTTPResponse {
        .response(statusCode: statusCode, headers: ["Content-Type": "text/plain"], body: Data(body.utf8))
    }

    var statusCode: Int { if case .response(let s, _, _) = self { return s } else { return 0 } }
    var headers: [String: String] { if case .response(_, let h, _) = self { return h } else { return [:] } }
    var body: Data { if case .response(_, _, let b) = self { return b } else { return Data() } }
}

/// Thread-safe FIFO queue of mock responses.
final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [MockHTTPResponse]

    init(_ responses: [MockHTTPResponse]) { self.responses = responses }

    func next() -> MockHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        guard !responses.isEmpty else { return .error(statusCode: 500, body: "No queued mock response") }
        return responses.removeFirst()
    }
}

/// Builds an `AppStoreConnectClient` whose `URLSession` is backed by `MockURLProtocol`
/// and which returns a fixed JWT (no real signing).
func makeClient(responses: [MockHTTPResponse]) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { _ in queue.next() }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" }
    )
}

func makeMockSession(handler: @escaping @Sendable (URLRequest) -> MockHTTPResponse) -> URLSession {
    let sessionID = UUID().uuidString
    MockURLProtocol.registerHandler(handler, for: sessionID)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Mock-Session-ID": sessionID]
    return URLSession(configuration: configuration)
}

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> MockHTTPResponse] = [:]
    nonisolated(unsafe) private static var latestSessionID: String?

    static func registerHandler(
        _ handler: @escaping @Sendable (URLRequest) -> MockHTTPResponse,
        for sessionID: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[sessionID] = handler
        latestSessionID = sessionID
    }

    private static func handler(for sessionID: String) -> (@Sendable (URLRequest) -> MockHTTPResponse)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[sessionID] ?? latestSessionID.flatMap { handlers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: "X-Mock-Session-ID")
        guard let handler = sessionID.flatMap(Self.handler(for:)) ?? Self.handler(for: "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        guard
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
