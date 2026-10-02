import Foundation

/// Validates modern per-request metadata and its mirrored HTTP headers.
/// Legacy initialization and requests with legacy headers keep their existing validation.
public struct ModernHTTPRequestValidator: HTTPRequestValidator {
    public init() {}

    public func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod == "POST", let body = request.body,
            let rpc = try? JSONDecoder().decode(AnyRequest.self, from: body)
        else { return nil }
        let headerVersion = request.header(HTTPHeaderName.protocolVersion)
        let modern =
            ProtocolRequestMetadata.isModern(rpc.params, method: rpc.method)
            || (headerVersion.map { !Version.legacySupported.contains($0) } ?? false)
        guard modern else { return nil }

        do {
            let metadata = try ProtocolRequestMetadata.parse(
                rpc.params,
                supportedVersions: context.supportedProtocolVersions.intersection(Version.modernSupported))
            if let acceptError = AcceptHeaderValidator(mode: .sseRequired).validate(request, context: context) {
                return acceptError
            }
            guard headerVersion == metadata.protocolVersion else {
                throw MCPError.headerMismatch("MCP-Protocol-Version must match params._meta protocolVersion")
            }
            guard let methodHeader = request.header(HTTPHeaderName.mcpMethod), methodHeader == rpc.method,
                methodHeader.utf8.allSatisfy({ (33...126).contains($0) })
            else {
                throw MCPError.headerMismatch("Mcp-Method must match method")
            }
            if [CallTool.name, GetPrompt.name, ReadResource.name].contains(rpc.method) {
                let key = rpc.method == ReadResource.name ? "uri" : "name"
                guard case .string(let value) = rpc.params.objectValue?[key] else {
                    throw MCPError.invalidParams("\(rpc.method) requires a string \(key)")
                }
                guard let header = request.header(HTTPHeaderName.mcpName), try Self.decodedHeader(header) == value else {
                    throw MCPError.headerMismatch("Mcp-Name must match params.\(key)")
                }
            }
        } catch MCPError.unsupportedProtocolVersion(let requested, _) {
            return .error(
                statusCode: 400,
                .unsupportedProtocolVersion(requested: requested, supported: context.supportedProtocolVersions.sorted(by: >)),
                requestID: rpc.id)
        } catch {
            return .error(statusCode: 400, error as? MCPError ?? .invalidParams(error.localizedDescription), requestID: rpc.id)
        }
        return nil
    }

    private static func decodedHeader(_ header: String) throws -> String {
        guard header.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
            throw MCPError.headerMismatch("Mcp-Name contains invalid header characters")
        }
        if header.hasPrefix("=?base64?"), header.hasSuffix("?=") {
            let encoded = String(header.dropFirst(9).dropLast(2))
            guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else {
                throw MCPError.headerMismatch("Mcp-Name has invalid Base64 encoding")
            }
            return decoded
        }
        guard header == header.trimmingCharacters(in: .whitespaces) else {
            throw MCPError.headerMismatch("Mcp-Name with surrounding whitespace must use Base64 encoding")
        }
        return header
    }
}
