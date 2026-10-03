import Foundation
import Logging

/// A stateless HTTP server transport that returns single JSON responses.
///
/// This transport implements a minimal subset of the MCP Streamable HTTP specification:
/// - No session management (no `Mcp-Session-Id` header)
/// - POST requests receive direct JSON responses (no SSE streaming)
/// - GET and DELETE requests return 405 Method Not Allowed
///
/// ## Usage
///
/// ```swift
/// let transport = StatelessHTTPServerTransport()
///
/// // Start the MCP server with this transport
/// try await server.start(transport: transport)
///
/// // In your HTTP framework handler:
/// let response = await transport.handleRequest(httpRequest)
/// // Convert response to your framework's response type and return it
/// ```
///
/// ## When to Use
///
/// Use this transport when:
/// - You don't need server-initiated messages (no GET SSE stream)
/// - You want simple request-response semantics
/// - Session management is handled externally or not needed
///
/// For full streaming and session support, use ``StatefulHTTPServerTransport`` instead.
public actor StatelessHTTPServerTransport: Transport, HTTPContextProviding {
    public nonisolated let logger: Logger

    // MARK: - Dependencies

    private let validationPipeline: any HTTPRequestValidationPipeline

    // MARK: - State

    private var terminated = false
    private var started = false

    // MARK: - Incoming message stream (client → server)

    private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - Response waiters

    /// Maps request ID → continuation waiting for the server's response.
    /// When the server calls `send()` with a response, the matching continuation is resumed.
    private var responseWaiters: [String: CheckedContinuation<Data, any Error>] = [:]

    /// Maps internal routing ID → originating HTTP request, surfaced via
    /// ``Server/currentHandlerContext``. Entries live only while a JSON-RPC request
    /// is in flight.
    private var httpRequestContexts: [String: HTTPRequest] = [:]

    /// Original IDs for legacy requests, whose cancellation notifications carry client IDs.
    private var legacyRequestIDs: [String: ID] = [:]

    // MARK: - Init

    /// Creates a new stateless HTTP server transport.
    ///
    /// - Parameters:
    ///   - validationPipeline: Custom validation pipeline. If `nil`, uses sensible defaults:
    ///     origin validation (localhost), Accept header (JSON only), Content-Type,
    ///     and protocol version validation.
    ///   - logger: Optional logger. If `nil`, a no-op logger is used.
    public init(
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        logger: Logger? = nil
    ) {
        self.validationPipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        self.logger = logger ?? Logger(
            label: "mcp.transport.http.server.stateless",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.incomingStream = stream
        self.incomingContinuation = continuation
    }

    // MARK: - Transport Conformance

    public func connect() async throws {
        guard !started else {
            throw MCPError.internalError("Transport already started")
        }
        started = true
        logger.debug("Stateless HTTP server transport started")
    }

    public func disconnect() async {
        await terminate()
    }

    /// Routes outgoing server messages to the appropriate waiting HTTP handler.
    ///
    /// - Responses are matched by JSON-RPC ID and delivered to the waiting `handleRequest` call.
    /// - Notifications and server-initiated requests are logged and dropped
    ///   (no streaming channel available in stateless mode).
    public func send(_ data: Data) async throws {
        guard !terminated else {
            throw MCPError.connectionClosed
        }

        guard let kind = JSONRPCMessageKind(data: data) else {
            logger.warning("Could not classify outgoing message for routing")
            return
        }

        switch kind {
        case .response(let id):
            guard let continuation = responseWaiters.removeValue(forKey: id) else {
                logger.debug(
                    "No waiter for response, may have timed out",
                    metadata: ["requestID": "\(id)"]
                )
                return
            }
            continuation.resume(returning: data)

        case .notification(let method):
            logger.debug(
                "Server-initiated notification dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )

        case .request(_, let method):
            logger.debug(
                "Server-initiated request dropped in stateless mode (no GET SSE stream)",
                metadata: ["method": "\(method)"]
            )
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        incomingStream
    }

    // MARK: - HTTP Request Handler

    /// Handles an incoming HTTP request from the framework adapter.
    ///
    /// Only POST is supported:
    /// - **POST**: JSON-RPC messages (requests, notifications)
    /// - **GET**: 405 Method Not Allowed
    /// - **DELETE**: 405 Method Not Allowed
    /// - Others: 405 Method Not Allowed
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if terminated {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Transport has been terminated")
            )
        }

        switch request.method.uppercased() {
        case "POST":
            return await handlePost(request)
        default:
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: [HTTPHeaderName.allow: "POST"]
            )
        }
    }

    // MARK: - POST Handler

    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        // Parse body first to determine message type
        guard let body = request.body, !body.isEmpty else {
            return .error(
                statusCode: 400,
                .parseError("Empty request body")
            )
        }

        guard let messageKind = JSONRPCMessageKind(data: body) else {
            return .error(
                statusCode: 400,
                .parseError("Invalid JSON-RPC message")
            )
        }

        // Build validation context
        let context = HTTPValidationContext(
            httpMethod: "POST",
            sessionID: nil,
            isInitializationRequest: messageKind.isInitializeRequest,
            supportedProtocolVersions: Version.supported
        )

        // Run validation pipeline
        if let errorResponse = validationPipeline.validate(request, context: context) {
            return errorResponse
        }

        // Handle by message type
        switch messageKind {
        case .response:
            return .error(statusCode: 400, .invalidRequest("Clients cannot POST JSON-RPC responses to a stateless server"))

        case .notification:
            if request.header(HTTPHeaderName.protocolVersion) == Version.latest {
                return .error(statusCode: 400, .invalidRequest("Modern HTTP requests are cancelled by closing the response, not by notification"))
            }
            if let notification = try? JSONDecoder().decode(Message<CancelledNotification>.self, from: body),
                notification.method == CancelledNotification.name,
                let externalID = notification.params.requestId
            {
                let matches = legacyRequestIDs.filter { internalID, id in
                    guard id == externalID, let original = httpRequestContexts[internalID] else { return false }
                    return original.header("Authorization") == request.header("Authorization")
                        && original.header(HTTPHeaderName.sessionID) == request.header(HTTPHeaderName.sessionID)
                }
                // Without a unique caller-scoped match, cancellation is ambiguous.
                // Never cancel another caller's work or all duplicate IDs.
                if matches.count == 1, let internalID = matches.first?.key {
                    cancelRequest(internalID, reason: notification.params.reason)
                }
                return .accepted()
            }
            // Yield to server and return 202 Accepted
            incomingContinuation.yield(body)
            return .accepted()

        case .request:
            guard let rpc = try? JSONDecoder().decode(AnyRequest.self, from: body) else {
                return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC request"))
            }
            return await handleJSONRPCRequest(rpc, request: request)
        }
    }

    private func handleJSONRPCRequest(
        _ rpc: AnyRequest,
        request: HTTPRequest
    ) async -> HTTPResponse {
        // Clients choose IDs independently. Route with a transport-generated ID so
        // concurrent clients (and string/number IDs with the same text) cannot collide.
        let requestID = UUID().uuidString
        let internalID = ID.string(requestID)
        let routed = AnyRequest(id: internalID, method: rpc.method, params: rpc.params)
        guard let body = try? JSONEncoder().encode(routed) else {
            return .error(statusCode: 400, .invalidRequest("Cannot encode request"), requestID: rpc.id)
        }
        httpRequestContexts[requestID] = request
        if !ProtocolRequestMetadata.isModern(rpc.params, method: rpc.method) {
            legacyRequestIDs[requestID] = rpc.id
        }
        defer {
            httpRequestContexts.removeValue(forKey: requestID)
            legacyRequestIDs.removeValue(forKey: requestID)
        }

        // Wait for the server to process and send a response
        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    responseWaiters[requestID] = continuation
                    incomingContinuation.yield(body)
                }
            } onCancel: {
                Task { await self.cancelRequest(requestID) }
            }
        } catch {
            return .error(
                statusCode: 500,
                .internalError("Error processing request: \(error.localizedDescription)"),
                requestID: rpc.id
            )
        }

        guard let response = try? JSONDecoder().decode(AnyResponse.self, from: responseData) else {
            return .error(statusCode: 500, .internalError("Invalid server response"), requestID: rpc.id)
        }
        if case .failure(let error) = response.result,
            ProtocolRequestMetadata.isModern(rpc.params, method: rpc.method)
        {
            if error.code == -32601 {
                return .error(statusCode: 404, error, requestID: rpc.id)
            }
            if [-32602, -32020, -32021, -32022].contains(error.code) {
                return .error(statusCode: 400, error, requestID: rpc.id)
            }
        }
        let externalResponse = AnyResponse(id: rpc.id, result: response.result)
        guard let data = try? JSONEncoder().encode(externalResponse) else {
            return .error(statusCode: 500, .internalError("Cannot encode server response"), requestID: rpc.id)
        }
        return .data(data, headers: [HTTPHeaderName.contentType: ContentType.json])
    }

    private func cancelRequest(_ requestID: String, reason: String? = "HTTP request closed") {
        guard let waiter = responseWaiters.removeValue(forKey: requestID) else { return }
        waiter.resume(throwing: CancellationError())
        let notification = CancelledNotification.message(.init(requestId: .string(requestID), reason: reason))
        if let data = try? JSONEncoder().encode(notification) {
            incomingContinuation.yield(data)
        }
    }

    // MARK: - HTTPContextProviding

    public func httpRequestContext(for id: ID) -> HTTPRequest? {
        httpRequestContexts[id.description]
    }

    // MARK: - Termination

    private func terminate() async {
        guard !terminated else { return }
        terminated = true

        logger.debug("Stateless HTTP server transport terminated")

        // Cancel all waiting continuations
        for (id, continuation) in responseWaiters {
            continuation.resume(throwing: MCPError.connectionClosed)
            logger.debug("Cancelled waiter for request", metadata: ["requestID": "\(id)"])
        }
        responseWaiters.removeAll()
        httpRequestContexts.removeAll()

        // Close incoming stream
        incomingContinuation.finish()
    }
}
