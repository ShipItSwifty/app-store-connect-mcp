import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A response type with no body content (e.g. 204 No Content).
///
/// Conform to this protocol for ASC endpoints that return an empty body.
public protocol EmptyBodyResponse: Decodable, Sendable {
    /// Creates an empty response value.
    init()
}

/// Default empty-body response used for 204 No Content ASC endpoints.
public struct NoContentResponse: EmptyBodyResponse {
    /// Creates a `NoContentResponse`.
    public init() {}
}

/// Actor-isolated client for the App Store Connect REST API.
///
/// Manages JWT lifecycle (via `JWTGenerator`), enforces rate-limit backoff
/// (via `RateLimiter`), and optionally routes through the ShipItSwifty
/// Vapor proxy server when `serverURL` is set.
///
/// All methods are `async throws`; errors are typed as `ASCError`.
///
/// ## Usage
/// ```swift
/// let client = AppStoreConnectClient(
///     keyID: "2X9R4HXF34",
///     issuerID: "57246542-96fe-1a63-e053-0824d011072a",
///     privateKeyData: p8Data
/// )
/// let apps: ASCListResponse<ASCApp> = try await client.get("/v1/apps")
/// ```
public actor AppStoreConnectClient {
    private static let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

    private let keyID: String
    private let issuerID: String
    private let privateKeyData: Data
    private let serverURL: URL?
    /// The URL session used for outbound HTTP. Package-internal so sibling
    /// extensions (e.g. artifact download) can reuse the configured session.
    let session: URLSession
    private let tokenProvider: (@Sendable () async throws -> String)?
    private let retryPolicy: TransientRetryPolicy
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger.forType(subsystem: "AppStoreConnectKit", AppStoreConnectClient.self)

    /// The JWT token generator used for authentication.
    public let jwtGenerator: JWTGenerator

    /// The rate limiter used to enforce Apple's API rate limits.
    ///
    /// `nonisolated` so callers (e.g. the MCP server's rate-limit heads-up) can read
    /// the limiter handle synchronously; it is an immutable `Sendable` actor reference.
    public nonisolated let rateLimiter: RateLimiter

    /// Creates an `AppStoreConnectClient`.
    ///
    /// - Parameters:
    ///   - keyID: The API Key ID from App Store Connect.
    ///   - issuerID: The Issuer ID from App Store Connect.
    ///   - privateKeyData: Raw `.p8` private key contents.
    ///   - serverURL: Optional proxy server URL (for use with `shipit-server`).
    ///   - session: URL session used for outbound HTTP requests.
    ///   - tokenProvider: Optional auth token provider used instead of `JWTGenerator`.
    ///   - retryPolicy: How `429`/`5xx` responses are retried. Pass ``TransientRetryPolicy/disabled``
    ///     to perform every request exactly once.
    public init(
        keyID: String,
        issuerID: String,
        privateKeyData: Data,
        serverURL: URL? = nil,
        session: URLSession = .shared,
        tokenProvider: (@Sendable () async throws -> String)? = nil,
        retryPolicy: TransientRetryPolicy = .default
    ) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyData = privateKeyData
        self.serverURL = serverURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.retryPolicy = retryPolicy
        self.jwtGenerator = JWTGenerator(keyID: keyID, issuerID: issuerID, privateKeyData: privateKeyData)
        self.rateLimiter = RateLimiter()

        // App Store Connect is camelCase on the wire in *both* directions
        // (`bundleId`, `versionString`, `whatsNew`, `appStoreVersion`, …), so no key
        // conversion strategy is applied. `.convertToSnakeCase` in particular silently
        // corrupted every POST/PATCH body — Apple ignores `version_string`.
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Generic REST

    /// Perform a GET request and decode the response.
    ///
    /// - Parameters:
    ///   - path: The API path (e.g. `"/v1/apps"`).
    ///   - query: Optional query parameters.
    /// - Returns: Decoded response of type `T`.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on non-2xx responses.
    public func get<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        let request = try await buildRequest(method: "GET", path: path, query: query, body: nil as EmptyBody?)
        return try await perform(request)
    }

    /// The largest page size App Store Connect accepts on a list endpoint.
    public static let maxPageSize = 200

    /// Perform a GET against a list endpoint and follow `links.next` until either the
    /// collection is exhausted or `limit` resources have been collected.
    ///
    /// A single `get` silently returns one page, so a workflow with more issues than
    /// the page size would lose the rest without any signal. This walks the pages
    /// instead, and the returned envelope's `links` are those of the final page —
    /// a non-nil `next` there means `limit` cut the walk short.
    ///
    /// - Parameters:
    ///   - path: The API path (e.g. `"/v1/ciProducts"`).
    ///   - query: Query parameters. Any `limit` key is replaced by the page size.
    ///   - limit: Maximum resources to return across all pages.
    /// - Returns: The accumulated resources, capped at `limit`.
    public func getAll<T: Codable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        limit: Int
    ) async throws -> ASCListResponse<T> {
        guard limit > 0 else { return ASCListResponse(data: []) }

        var query = query
        query["limit"] = String(min(limit, Self.maxPageSize))

        var collected: [T] = []
        var page: ASCListResponse<T> = try await get(path, query: query)

        while true {
            collected += page.data
            guard collected.count < limit,
                let next = page.links?.next,
                let nextURL = URL(string: next)
            else { break }

            let request = try await buildRequest(url: nextURL, method: "GET", body: nil as EmptyBody?)
            page = try await perform(request)
            guard !page.data.isEmpty else { break }
        }

        return ASCListResponse(data: Array(collected.prefix(limit)), links: page.links)
    }

    /// Perform a POST request with a body and decode the response.
    ///
    /// - Parameters:
    ///   - path: The API path.
    ///   - body: The request body (encoded as JSON).
    /// - Returns: Decoded response of type `Response`.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on non-2xx responses.
    public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let request = try await buildRequest(method: "POST", path: path, query: [:], body: body)
        return try await perform(request)
    }

    /// Perform a PATCH request with a body and decode the response.
    ///
    /// - Parameters:
    ///   - path: The API path.
    ///   - body: The request body (encoded as JSON).
    /// - Returns: Decoded response of type `Response`.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on non-2xx responses.
    public func patch<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        let request = try await buildRequest(method: "PATCH", path: path, query: [:], body: body)
        return try await perform(request)
    }

    /// Perform a DELETE request.
    ///
    /// App Store Connect answers a successful delete with `204 No Content`, so this
    /// returns nothing rather than a decoded body.
    ///
    /// - Parameter path: The API path (e.g. `"/v1/betaTesters/{id}"`).
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on non-2xx responses.
    public func delete(_ path: String) async throws {
        let request = try await buildRequest(method: "DELETE", path: path, query: [:], body: nil as EmptyBody?)
        let _: NoContentResponse = try await perform(request)
    }

    /// Perform a DELETE request that carries a body, as the relationship endpoints
    /// (`…/relationships/…`) require.
    public func delete<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
        let request = try await buildRequest(method: "DELETE", path: path, query: [:], body: body)
        let _: NoContentResponse = try await perform(request)
    }

    /// Perform a GET and return the response body verbatim, without decoding it.
    ///
    /// This is the escape hatch for the parts of the App Store Connect API this package
    /// has no typed model for: the caller (for example an AI agent driving the MCP
    /// server) gets Apple's JSON as-is, including `included` sidecars and any attribute
    /// added after this package was built.
    ///
    /// - Parameters:
    ///   - path: The API path (e.g. `"/v1/apps"`).
    ///   - query: Query parameters, passed through untouched — `filter[…]`, `fields[…]`,
    ///     `include`, `sort`, `limit` all work.
    /// - Returns: The raw 2xx response body.
    public func getRaw(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let request = try await buildRequest(method: "GET", path: path, query: query, body: nil as EmptyBody?)
        return try await performData(request).data
    }

    // MARK: - Asset Upload

    /// Upload an asset (IPA, screenshot, preview) using the multi-step protocol.
    ///
    /// Implements the 3-step App Store Connect upload protocol:
    /// 1. Upload parts to presigned URLs
    /// 2. Commit the upload with MD5 checksum
    ///
    /// - Parameters:
    ///   - fileURL: Local file URL of the asset to upload.
    ///   - reservation: The reservation returned by a prior ASC API call.
    /// - Returns: The upload commit, which should be sent to ASC to finalize.
    /// - Throws: ``ASCError/uploadFailed(asset:reason:)`` on failure.
    public func uploadAsset(at fileURL: URL, reservation: UploadReservation) async throws -> UploadCommit {
        logger.info("Uploading asset: \(fileURL.lastPathComponent)")
        let uploader = AssetUploader(session: session)
        return try await uploader.upload(fileURL: fileURL, to: reservation) { progress in
            self.logger.debug("Upload progress: \(Int(progress * 100))%")
        }
    }

    // MARK: - Private Helpers

    private func buildRequest<Body: Encodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> URLRequest {
        let baseURL = serverURL ?? AppStoreConnectClient.baseURL
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)

        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components?.url else {
            throw ASCError.invalidConfiguration(reason: "Invalid URL for path: \(path)")
        }
        return try await buildRequest(url: url, method: method, body: body)
    }

    /// Builds an authorized request against an already-resolved URL — used for
    /// pagination, where the `links.next` URL arrives fully formed.
    private func buildRequest<Body: Encodable>(
        url: URL,
        method: String,
        body: Body?
    ) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token: String
        if let tokenProvider {
            token = try await tokenProvider()
        } else {
            token = try await jwtGenerator.cachedOrNewToken()
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            let bodyData = try encoder.encode(body)
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let (data, statusCode) = try await performData(request)

        if data.isEmpty {
            guard let emptyResponseType = T.self as? any EmptyBodyResponse.Type else {
                throw ASCError.apiError(
                    statusCode: statusCode,
                    body: "Received empty response body for \(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
                )
            }
            guard let result = emptyResponseType.init() as? T else {
                throw ASCError.apiError(
                    statusCode: statusCode,
                    body: "Empty-body response type mismatch: expected \(T.self)"
                )
            }
            return result
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            // A raw `DecodingError` names a coding path and nothing else; an agent (or a
            // human) needs to know *which* response failed to decode to act on it.
            throw ASCError.decodingFailed(
                path: request.url?.path ?? "",
                type: String(describing: T.self),
                underlying: decodingError
            )
        }
    }

    /// Sends a request, retrying transient failures, and returns the raw 2xx body.
    ///
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on a non-2xx response that the
    ///   retry policy did not (or could no longer) retry.
    private func performData(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        var attempt = 1
        while true {
            await rateLimiter.throttleIfNeeded()

            logger.debug("ASC API \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ASCError.apiError(statusCode: 0, body: "Invalid response type")
            }

            // Update rate limiter from response headers
            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    dict[key] = value
                }
            }
            await rateLimiter.update(from: headers)

            logger.debug("ASC API response: \(httpResponse.statusCode)")

            if (200..<300).contains(httpResponse.statusCode) {
                return (data, httpResponse.statusCode)
            }

            let method = request.httpMethod ?? "GET"
            if attempt < retryPolicy.maxAttempts,
                retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, method: method)
            {
                let wait = retryPolicy.delay(
                    forAttempt: attempt,
                    retryAfter: TransientRetryPolicy.retryAfter(from: headers)
                )
                let path = request.url?.path ?? ""
                logger.warning(
                    "ASC API \(httpResponse.statusCode) on \(method) \(path); retrying in \(wait) (attempt \(attempt + 1) of \(retryPolicy.maxAttempts))"
                )
                try await Task.sleep(for: wait)
                attempt += 1
                continue
            }

            let body = String(decoding: data, as: UTF8.self)
            logger.error("ASC API error \(httpResponse.statusCode): \(body)")
            throw ASCError.apiError(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Helpers

private struct EmptyBody: Encodable, Sendable {}
