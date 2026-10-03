import Foundation
import MCP
import Testing

@testable import AppStoreConnectMCPServer

private enum WireTimeout: Error { case expired }

private func withinDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw WireTimeout.expired
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

private let modernMeta: [String: Value] = [
    ProtocolMetadataKey.protocolVersion: .string("2026-07-28"),
    ProtocolMetadataKey.clientCapabilities: .object([:]),
]

private func requestData(_ method: String, id: Value = .int(1), params: [String: Value] = [:], modern: Bool = true) throws -> Data {
    var params = params
    if modern { params["_meta"] = params["_meta"] ?? .object(modernMeta) }
    return try JSONEncoder().encode(
        Value.object([
            "jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(params),
        ]))
}

private struct WireHarness: Sendable {
    let transport: InMemoryTransport
    let responses: AsyncThrowingStream<Data, any Error>

    func call(_ method: String, params: [String: Value] = [:], modern: Bool = true) async throws -> [String: Value] {
        let data = try requestData(method, params: params, modern: modern)
        return try await withinDeadline {
            try await transport.send(data)
            var iterator = responses.makeAsyncIterator()
            let response = try await #require(iterator.next())
            return try #require(JSONDecoder().decode(Value.self, from: response).objectValue)
        }
    }
}

private func withWireServer(_ operation: @Sendable (WireHarness, Server) async throws -> Void) async throws {
    let pair = await InMemoryTransport.createConnectedPair()
    let server = await AppStoreConnectMCP.makeServer(makeClient: {
        makeMockMCPClient([jsonCanned(["data": []])])
    })
    try await server.start(transport: pair.server)
    try await pair.client.connect()
    let harness = WireHarness(transport: pair.client, responses: await pair.client.receive())
    do {
        try await operation(harness, server)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

@Suite("Modern and legacy MCP wire protocol", .serialized)
struct ModernProtocolTests {
    @Test("Cancelled handlers that return a result do not emit a late stdio response")
    func cancellationWithSwallowedError() async throws {
        try await withWireServer { wire, server in
            let started = AsyncStream<Void>.makeStream()
            let cancelled = AsyncStream<Void>.makeStream()
            await server.withMethodHandler(ContextProbe.self) { _ in
                started.continuation.yield(())
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    cancelled.continuation.yield(())
                }
                return .object([:])
            }
            try await wire.transport.send(requestData(ContextProbe.name))
            try await withinDeadline {
                var iterator = started.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            try await wire.transport.send(JSONEncoder().encode(CancelledNotification.message(.init(requestId: .number(1)))))
            try await withinDeadline {
                var iterator = cancelled.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            await server.withMethodHandler(ContextProbe.self) { _ in
                try await Task.sleep(for: .milliseconds(30))
                return .object([:])
            }
            try await wire.transport.send(requestData(ContextProbe.name, id: .int(2)))
            let response = try await withinDeadline {
                var iterator = wire.responses.makeAsyncIterator()
                return try #require(await iterator.next())
            }
            #expect(try JSONDecoder().decode(Value.self, from: response).objectValue?["id"] == .int(2))
        }
    }

    @Test("Modern discovery is complete and does not select a legacy session")
    func discoveryAndLegacy() async throws {
        try await withWireServer { wire, _ in
            let discover = try await wire.call("server/discover")
            let result = try #require(discover["result"]?.objectValue)
            #expect(result["resultType"] == .string("complete"))
            #expect(result["supportedVersions"]?.arrayValue?.contains(.string("2026-07-28")) == true)
            #expect(result["_meta"]?.objectValue?[ProtocolMetadataKey.serverInfo]?.objectValue?["name"] == .string("app-store-connect-mcp"))
            #expect(result["instructions"]?.stringValue?.isEmpty == false)
            #expect(result["ttlMs"] == .int(0))
            #expect(result["cacheScope"] == .string("private"))
            #expect(result["capabilities"]?.objectValue?["resources"]?.objectValue?["subscribe"] == nil)

            let initialized = try await wire.call(
                "initialize",
                params: [
                    "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("legacy"), "version": .string("1")]),
                ], modern: false)
            #expect(initialized["result"]?.objectValue?["protocolVersion"] == .string("2025-11-25"))
            #expect(initialized["result"]?.objectValue?["resultType"] == nil)
            let tools = try await wire.call("tools/list", modern: false)
            #expect(tools["result"]?.objectValue?["tools"]?.arrayValue?.isEmpty == false)
            #expect(tools["result"]?.objectValue?["resultType"] == nil)
            #expect(tools["result"]?.objectValue?["ttlMs"] == nil)

            let modernTools = try await wire.call("tools/list")
            #expect(modernTools["result"]?.objectValue?["resultType"] == .string("complete"))
        }
    }

    @Test("Lists, reads, prompts and tool calls work without discovery or initialization")
    func inlineRequests() async throws {
        try await withWireServer { wire, _ in
            for method in ["tools/list", "resources/list", "resources/templates/list", "prompts/list"] {
                let response = try await wire.call(method)
                let result = try #require(response["result"]?.objectValue)
                #expect(result["resultType"] == .string("complete"))
                #expect(result["ttlMs"] == .int(0))
                #expect(result["cacheScope"] == .string("private"))
            }
            let resource = try await wire.call("resources/read", params: ["uri": .string("asc://apps")])
            #expect(resource["result"]?.objectValue?["contents"]?.arrayValue?.isEmpty == false)
            #expect(resource["result"]?.objectValue?["cacheScope"] == .string("private"))
            let prompt = try await wire.call("prompts/get", params: ["name": .string("triage_ci_failure")])
            #expect(prompt["result"]?.objectValue?["resultType"] == .string("complete"))
            let tool = try await wire.call("tools/call", params: ["name": .string("asc_list_apps")])
            #expect(tool["result"]?.objectValue?["resultType"] == .string("complete"))
            #expect(tool["result"]?.objectValue?["isError"] != .bool(true))
        }
    }

    @Test("Unsupported versions return structured protocol errors")
    func versionMismatch() async throws {
        try await withWireServer { wire, _ in
            var meta = modernMeta
            meta[ProtocolMetadataKey.protocolVersion] = .string("2099-01-01")
            let response = try await wire.call("tools/list", params: ["_meta": .object(meta)])
            let error = try #require(response["error"]?.objectValue)
            #expect(error["code"] == .int(-32_022))
            #expect(error["data"]?.objectValue?["requested"] == .string("2099-01-01"))
            #expect(error["data"]?.objectValue?["supported"]?.arrayValue?.contains(.string("2026-07-28")) == true)
        }
    }

    @Test("Missing metadata and malformed parameters are invalid params, never silent or internal errors")
    func malformedRequests() async throws {
        try await withWireServer { wire, _ in
            let malformedMetadata: [[String: Value]] = [
                [:], [ProtocolMetadataKey.protocolVersion: .string("2026-07-28")],
                [ProtocolMetadataKey.protocolVersion: .int(2), ProtocolMetadataKey.clientCapabilities: .object([:])],
            ]
            for meta in malformedMetadata {
                let response = try await wire.call("server/discover", params: ["_meta": .object(meta)])
                #expect(response["error"]?.objectValue?["code"] == .int(-32_602))
            }
            let missing = try await wire.call("tools/list", modern: false)
            #expect(missing["error"]?.objectValue?["code"] == .int(-32_602))
            let malformed = try await wire.call("tools/call", params: ["name": .int(7)])
            #expect(malformed["error"]?.objectValue?["code"] == .int(-32_602))
            // Processing continues after errors.
            let response = try await wire.call("tools/list")
            #expect(response["result"] != nil)
        }
    }

    @Test("Removed methods cannot execute under modern semantics")
    func removedMethods() async throws {
        try await withWireServer { wire, _ in
            for method in ["initialize", "ping", "logging/setLevel", "resources/subscribe", "resources/unsubscribe"] {
                let response = try await wire.call(method)
                #expect(response["error"]?.objectValue?["code"] == .int(-32_601))
            }
        }
    }

    @Test("Per-request client capabilities remain independent on the same process")
    func independentCapabilities() async throws {
        try await withWireServer { wire, server in
            await server.withMethodHandler(ContextProbe.self) { _ in
                let metadata = try #require(Server.currentHandlerContext?.protocolMetadata)
                return .object(["hasRoots": .bool(metadata.clientCapabilities.roots != nil)])
            }
            var meta = modernMeta
            meta[ProtocolMetadataKey.clientCapabilities] = .object(["roots": .object([:])])
            let withRoots = try await wire.call(ContextProbe.name, params: ["_meta": .object(meta)])
            let withoutRoots = try await wire.call(ContextProbe.name)
            #expect(withRoots["result"]?.objectValue?["hasRoots"] == .bool(true))
            #expect(withoutRoots["result"]?.objectValue?["hasRoots"] == .bool(false))
        }
    }

    @Test("New errors preserve data through coding and the client keeps its legacy default")
    func errorCodingAndLegacyDefaults() throws {
        for error in [
            MCPError.unsupportedProtocolVersion(requested: "2099-01-01", supported: ["2026-07-28"]),
            .headerMismatch("Mcp-Name"), .missingRequiredClientCapability(requiredCapabilities: ["elicitation": .object([:])]),
        ] {
            #expect(try JSONDecoder().decode(MCPError.self, from: JSONEncoder().encode(error)) == error)
        }
        let initParams = Initialize.Parameters(capabilities: .init(), clientInfo: .init(name: "legacy", version: "1"))
        #expect(initParams.protocolVersion == "2025-11-25")
    }

    @Test("Missing capability errors use the spec's capabilities object and logging requires opt-in")
    func capabilityErrorAndLogging() async throws {
        try await withWireServer { wire, server in
            await server.withMethodHandler(ContextProbe.self) { _ in
                try await server.notify(LogMessageNotification.message(.init(level: .info, data: .string("not opted in"))))
                _ = try await server.listRoots()
                return .object([:])
            }
            let response = try await wire.call(ContextProbe.name)
            let error = try #require(response["error"]?.objectValue)
            #expect(error["code"] == .int(-32_021))
            #expect(error["data"]?.objectValue?["requiredCapabilities"] == .object(["roots": .object([:])]))
        }
    }

    @Test("Every advertised tool has a title and the appropriate review hints")
    func toolReviewMetadata() {
        for spec in CITools.specs(writesEnabled: true) {
            #expect(spec.tool.title?.isEmpty == false)
            #expect(spec.tool.annotations.title == spec.tool.title)
            #expect(spec.tool.annotations.readOnlyHint == spec.isReadOnly)
            #expect(spec.tool.annotations.destructiveHint == !spec.isReadOnly)
            #expect(spec.tool.name.count <= 64)
        }
    }
}

private enum ContextProbe: MCP.Method {
    static let name = "test/context"
    typealias Parameters = Value
    typealias Result = Value
}

@Suite("Modern stateless HTTP", .serialized)
struct ModernHTTPProtocolTests {
    @Test("Unknown modern methods return HTTP 404 with the original request ID")
    func unknownMethodStatus() async throws {
        let transport = transport()
        let server = Server(name: "unknown-method", version: "1", configuration: .strict)
        try await server.start(transport: transport)
        let request = try request("unknown/method", id: .string("client-id"))
        let response = try await withinDeadline { await transport.handleRequest(request) }
        await server.stop()
        #expect(response.statusCode == 404)
        let rpc = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        #expect(rpc.objectValue?["id"] == .string("client-id"))
        #expect(rpc.objectValue?["error"]?.objectValue?["code"] == .int(-32_601))
    }

    @Test("Legacy HTTP cancellation translates client IDs and isolates authorization contexts")
    func legacyCancellation() async throws {
        let transport = transport()
        let server = Server(name: "legacy-cancellation", version: "1")
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        await server.withMethodHandler(ContextProbe.self) { _ in
            started.continuation.yield(())
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError {
                cancelled.continuation.yield(())
                throw CancellationError()
            }
            return .object([:])
        }
        try await server.start(transport: transport)
        let headers = [
            "Host": "localhost:8080", "Accept": "application/json", "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-11-25", "Authorization": "Bearer caller-a",
        ]
        let http = HTTPRequest(
            method: "POST", headers: headers,
            body: try requestData(ContextProbe.name, id: .string("external-id"), modern: false))
        let call = Task { await transport.handleRequest(http) }
        do {
            try await withinDeadline {
                var iterator = started.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            let body = try JSONEncoder().encode(CancelledNotification.message(.init(requestId: .string("external-id"))))
            var otherHeaders = headers
            otherHeaders["Authorization"] = "Bearer caller-b"
            #expect(await transport.handleRequest(HTTPRequest(method: "POST", headers: otherHeaders, body: body)).statusCode == 202)
            #expect(await transport.handleRequest(HTTPRequest(method: "POST", headers: headers, body: body)).statusCode == 202)
            try await withinDeadline {
                var iterator = cancelled.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            _ = try await withinDeadline { await call.value }
            await server.stop()
        } catch {
            call.cancel()
            await server.stop()
            throw error
        }
    }

    private func transport() -> StatelessHTTPServerTransport {
        StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(), AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(), ProtocolVersionValidator(),
            ]))
    }

    private func request(
        _ method: String, id: Value = .int(1), params: [String: Value] = [:], headers: [String: String] = [:]
    ) throws -> HTTPRequest {
        var merged = [
            "Host": "localhost:8080", "Accept": "application/json, text/event-stream", "Content-Type": "application/json",
            "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method,
        ]
        merged.merge(headers) { _, value in value }
        return HTTPRequest(method: "POST", headers: merged, body: try requestData(method, id: id, params: params))
    }

    @Test("HTTP header validation checks presence, body equality, and Base64 encoding")
    func headers() throws {
        let validator = ModernHTTPRequestValidator()
        let context = HTTPValidationContext(httpMethod: "POST")
        #expect(validator.validate(try request("tools/list"), context: context) == nil)
        for header in ["MCP-Protocol-Version", "Mcp-Method", "Mcp-Name"] {
            let full = try request("tools/call", params: ["name": .string("asc_list_apps")], headers: ["Mcp-Name": "asc_list_apps"])
            var headers = full.headers
            headers.removeValue(forKey: header)
            let invalid = HTTPRequest(method: "POST", headers: headers, body: full.body)
            let response = try #require(validator.validate(invalid, context: context))
            #expect(response.statusCode == 400)
            let rpc = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
            #expect(rpc.objectValue?["id"] == .int(1))
            #expect(rpc.objectValue?["error"]?.objectValue?["code"] == .int(-32_020))
        }
        let mismatch = try request("tools/call", params: ["name": .string("asc_list_apps")], headers: ["Mcp-Name": "other"])
        #expect(validator.validate(mismatch, context: context)?.statusCode == 400)
        let uri = "asc://apps/世界"
        let encoded = "=?base64?" + Data(uri.utf8).base64EncodedString() + "?="
        #expect(
            validator.validate(
                try request("resources/read", params: ["uri": .string(uri)], headers: ["Mcp-Name": encoded]), context: context) == nil)
        #expect(
            validator.validate(try request("resources/read", params: ["uri": .string(uri)], headers: ["Mcp-Name": uri]), context: context)?
                .statusCode == 400)
        #expect(
            validator.validate(
                try request("prompts/get", params: ["name": .string("x")], headers: ["Mcp-Name": "=?base64?%%%?="]), context: context)?
                .statusCode == 400)
        #expect(validator.validate(try request("tools/list", headers: ["Accept": "application/json"]), context: context)?.statusCode == 406)
    }

    @Test("HTTP version errors preserve negotiation data and invalid metadata returns 400")
    func metadataErrors() throws {
        let validator = ModernHTTPRequestValidator()
        var meta = modernMeta
        meta[ProtocolMetadataKey.protocolVersion] = .string("2099-01-01")
        let invalid = try request("tools/list", params: ["_meta": .object(meta)], headers: ["MCP-Protocol-Version": "2099-01-01"])
        let response = try #require(validator.validate(invalid, context: HTTPValidationContext(httpMethod: "POST")))
        #expect(response.statusCode == 400)
        let rpc = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        #expect(rpc.objectValue?["error"]?.objectValue?["data"]?.objectValue?["requested"] == .string("2099-01-01"))
        let missing = try request("tools/list", params: ["_meta": .object([:])])
        #expect(validator.validate(missing, context: HTTPValidationContext(httpMethod: "POST"))?.statusCode == 400)
    }

    @Test("Concurrent clients reuse IDs without sharing auth context or responses")
    func collidingIDs() async throws {
        let transport = transport()
        let server = Server(name: "context-check", version: "1", configuration: .strict)
        await server.withMethodHandler(ContextProbe.self) { _ in
            let auth = try #require(Server.currentHandlerContext?.httpContext?.header("Authorization"))
            try await Task.sleep(for: .milliseconds(30))
            let after = Server.currentHandlerContext?.httpContext?.header("Authorization")
            #expect(auth == after)
            return .object(["auth": .string(auth)])
        }
        try await server.start(transport: transport)
        do {
            for ids in [[Value.int(1), .int(1)], [.int(1), .string("1")]] {
                let first = try request(ContextProbe.name, id: ids[0], headers: ["Authorization": "Bearer first-test-token"])
                let second = try request(ContextProbe.name, id: ids[1], headers: ["Authorization": "Bearer second-test-token"])
                let responses = try await withinDeadline {
                    async let a = transport.handleRequest(first)
                    async let b = transport.handleRequest(second)
                    return await (a, b)
                }
                for (response, expectedID, auth) in [
                    (responses.0, ids[0], "Bearer first-test-token"), (responses.1, ids[1], "Bearer second-test-token"),
                ] {
                    #expect(response.statusCode == 200)
                    #expect(response.headers["MCP-Session-Id"] == nil)
                    let rpc = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
                    #expect(rpc.objectValue?["id"] == expectedID)
                    #expect(rpc.objectValue?["result"]?.objectValue?["auth"] == .string(auth))
                }
            }
            #expect(await transport.handleRequest(HTTPRequest(method: "GET")).statusCode == 405)
            #expect(await transport.handleRequest(HTTPRequest(method: "DELETE")).statusCode == 405)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test("Closing the HTTP handler cancels server work and releases its waiter")
    func cancellation() async throws {
        let transport = transport()
        let server = Server(name: "cancellation-check", version: "1", configuration: .strict)
        let started = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        await server.withMethodHandler(ContextProbe.self) { _ in
            started.continuation.yield(())
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancelled.continuation.yield(())
                throw CancellationError()
            }
            return .object([:])
        }
        try await server.start(transport: transport)
        let httpRequest = try request(ContextProbe.name)
        let call = Task { await transport.handleRequest(httpRequest) }
        do {
            try await withinDeadline {
                var iterator = started.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            call.cancel()
            _ = try await withinDeadline { await call.value }
            try await withinDeadline {
                var iterator = cancelled.stream.makeAsyncIterator()
                _ = try #require(await iterator.next())
            }
            await server.stop()
        } catch {
            call.cancel()
            await server.stop()
            throw error
        }
    }
}
