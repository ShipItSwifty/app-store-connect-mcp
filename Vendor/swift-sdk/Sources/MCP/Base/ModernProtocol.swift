import Foundation

/// Reserved per-request and per-result metadata keys in revision 2026-07-28.
public enum ProtocolMetadataKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
}

/// Validated metadata for one modern request. Never stored as connection state.
public struct ProtocolRequestMetadata: Hashable, Sendable {
    public let protocolVersion: String
    public let clientCapabilities: Client.Capabilities
    public let clientInfo: Client.Info?
    public let metadata: Metadata

    /// Whether the body declares modern semantics, including an incomplete declaration.
    static func isModern(_ params: Value, method: String) -> Bool {
        if method == Discover.name { return true }
        guard let meta = params.objectValue?["_meta"]?.objectValue else { return false }
        return meta[ProtocolMetadataKey.protocolVersion] != nil || meta[ProtocolMetadataKey.clientCapabilities] != nil
    }

    static func parse(_ params: Value, supportedVersions: Set<String> = Version.modernSupported) throws -> Self {
        guard let fields = params.objectValue?["_meta"]?.objectValue,
            case .string(let version) = fields[ProtocolMetadataKey.protocolVersion],
            case .object = fields[ProtocolMetadataKey.clientCapabilities]
        else {
            throw MCPError.invalidParams(
                "Every modern request requires a string protocolVersion and an object clientCapabilities in params._meta")
        }
        guard supportedVersions.contains(version) else {
            throw MCPError.unsupportedProtocolVersion(requested: version, supported: supportedVersions.sorted(by: >))
        }
        do {
            let capabilities = try JSONDecoder().decode(
                Client.Capabilities.self, from: JSONEncoder().encode(fields[ProtocolMetadataKey.clientCapabilities]))
            if let extensions = capabilities.extensions, extensions.values.contains(where: { $0.objectValue == nil }) {
                throw MCPError.invalidParams("Extension settings must be objects")
            }
            let clientInfo = try fields[ProtocolMetadataKey.clientInfo].map {
                try JSONDecoder().decode(Client.Info.self, from: JSONEncoder().encode($0))
            }
            if let level = fields[ProtocolMetadataKey.logLevel] {
                _ = try JSONDecoder().decode(LogLevel.self, from: JSONEncoder().encode(level))
            }
            return Self(
                protocolVersion: version, clientCapabilities: capabilities, clientInfo: clientInfo,
                metadata: Metadata(additionalFields: fields))
        } catch {
            throw MCPError.invalidParams("Invalid client capabilities, identity, or log level in params._meta")
        }
    }
}

/// Stateless server discovery. It does not establish a session or initialize the server.
public enum Discover: Method {
    public static let name = "server/discover"

    public struct Parameters: Hashable, Codable, Sendable {
        public var _meta: Metadata

        public init(meta: Metadata) {
            self._meta = meta
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let resultType: String
        public let supportedVersions: [String]
        public let capabilities: Server.Capabilities
        public let instructions: String?
        public var _meta: Metadata?
        public let ttlMs: Int
        public let cacheScope: String

        public init(supportedVersions: [String], capabilities: Server.Capabilities, instructions: String? = nil) {
            self.resultType = "complete"
            self.supportedVersions = supportedVersions
            self.capabilities = capabilities
            self.instructions = instructions
            self._meta = nil
            self.ttlMs = 0
            self.cacheScope = "private"
        }
    }
}

extension Server {
    /// Add modern envelope fields only after dispatch; legacy typed results stay unchanged.
    static func modernResponse(_ response: AnyResponse, method: String, serverInfo: Info) throws -> AnyResponse {
        guard case .success(let value) = response.result else { return response }
        guard var result = value.objectValue else {
            throw MCPError.internalError("MCP results must be objects")
        }
        result["resultType"] = result["resultType"] ?? .string("complete")
        var meta = result["_meta"]?.objectValue ?? [:]
        meta[ProtocolMetadataKey.serverInfo] = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(serverInfo))
        result["_meta"] = .object(meta)
        let cacheable = [
            Discover.name, ListTools.name, ListPrompts.name, ListResources.name, ListResourceTemplates.name, ReadResource.name,
        ]
        if cacheable.contains(method), result["resultType"] == .string("complete") {
            // Conservative defaults: no reuse or shared caching of account-specific data.
            result["ttlMs"] = result["ttlMs"] ?? .int(0)
            result["cacheScope"] = result["cacheScope"] ?? .string("private")
        }
        if method == Discover.name, var capabilities = result["capabilities"]?.objectValue {
            for key in ["tools", "prompts", "resources"] {
                if var capability = capabilities[key]?.objectValue {
                    capability.removeValue(forKey: "listChanged")
                    capability.removeValue(forKey: "subscribe")
                    capabilities[key] = .object(capability)
                }
            }
            result["capabilities"] = .object(capabilities)
        }
        return AnyResponse(id: response.id, result: .object(result))
    }
}
