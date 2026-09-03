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

/// Small lock-guarded box so mock handlers can record what they saw.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { self.storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
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
/// Retrying is off by default here: most tests queue exactly one response per
/// request and assert the error a non-2xx produces, which a retry would swallow (and
/// pay for with a real backoff sleep). Tests that exercise retrying opt in.
func makeClient(
    responses: [MockHTTPResponse],
    retryPolicy: TransientRetryPolicy = .disabled
) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { _ in queue.next() }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" },
        retryPolicy: retryPolicy
    )
}

/// Like `makeClient(responses:)` but records the full request URL (path *and* query)
/// of every request, so tests can assert the filters and sort a helper sends.
func makeClientRecording(
    observedURLs: LockedBox<[String]>,
    responses: [MockHTTPResponse],
    retryPolicy: TransientRetryPolicy = .disabled
) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { request in
        observedURLs.mutate { $0.append(request.url?.absoluteString ?? "") }
        return queue.next()
    }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" },
        retryPolicy: retryPolicy
    )
}

/// Like `makeClient(responses:)` but records the `path` of every request the client
/// makes into `observedPaths`, in order, so tests can assert which endpoints were hit.
func makeClientRecording(
    observedPaths: LockedBox<[String]>,
    responses: [MockHTTPResponse]
) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { request in
        observedPaths.mutate { $0.append(request.url?.path ?? "") }
        return queue.next()
    }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" }
    )
}

/// Like `makeClient(responses:)` but records the JSON body of every request that has
/// one, so tests can assert what was actually sent on the wire.
///
/// Guards the encoding of write requests: App Store Connect requires camelCase keys,
/// and nothing else in the suite looks at an outgoing body.
func makeClientRecording(
    observedBodies: LockedBox<[[String: Any]]>,
    responses: [MockHTTPResponse]
) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { request in
        if let data = request.bodyData,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            observedBodies.mutate { $0.append(object) }
        }
        return queue.next()
    }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" }
    )
}

extension URLRequest {
    /// The request body, read from `httpBodyStream` when `URLSession` has already
    /// converted `httpBody` into a stream (which it does before reaching a `URLProtocol`).
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// Like `makeClient(responses:)` but records the HTTP method of every request.
func makeClientRecording(
    observedMethods: LockedBox<[String]>,
    responses: [MockHTTPResponse]
) -> AppStoreConnectClient {
    let queue = ResponseQueue(responses)
    let session = makeMockSession { request in
        observedMethods.mutate { $0.append(request.httpMethod ?? "") }
        return queue.next()
    }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" }
    )
}

/// Builds a client whose responses are matched by URL substring rather than by
/// arrival order.
///
/// Helpers that issue requests concurrently (`async let`) have no defined order, so a
/// FIFO queue hands them each other's responses. Routing by path pins each response to
/// the endpoint it belongs to.
func makeClientRouting(
    _ routes: [(pathContains: String, response: MockHTTPResponse)],
    retryPolicy: TransientRetryPolicy = .disabled
) -> AppStoreConnectClient {
    let session = makeMockSession { request in
        let url = request.url?.absoluteString ?? ""
        guard let route = routes.first(where: { url.contains($0.pathContains) }) else {
            return .error(statusCode: 500, body: "No mock route matches \(url)")
        }
        return route.response
    }
    return AppStoreConnectClient(
        keyID: "KEY",
        issuerID: "ISSUER",
        privateKeyData: Data("placeholder".utf8),
        session: session,
        tokenProvider: { "test-token" },
        retryPolicy: retryPolicy
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
