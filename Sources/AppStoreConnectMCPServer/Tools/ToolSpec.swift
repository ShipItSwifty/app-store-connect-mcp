import AppStoreConnectKit
import Foundation
import MCP

extension Tool.Content {
    /// A plain text content block.
    ///
    /// The SDK's `.text(_:)` / `.text(text:metadata:)` convenience factories are
    /// deprecated in favour of the three-argument case; this keeps call sites short
    /// without reaching for a deprecated overload.
    static func plainText(_ text: String) -> Self {
        .text(text: text, annotations: nil, _meta: nil)
    }
}

/// One argument of a ``ToolSpec``, from which the JSON Schema is generated.
struct ToolArgument: Sendable {
    /// The JSON Schema primitive type this argument accepts.
    enum Kind: String, Sendable {
        case string
        case integer
        case boolean
    }

    let name: String
    let kind: Kind
    let description: String
    let isRequired: Bool

    static func string(_ name: String, _ description: String, required: Bool = false) -> ToolArgument {
        ToolArgument(name: name, kind: .string, description: description, isRequired: required)
    }

    static func integer(_ name: String, _ description: String) -> ToolArgument {
        ToolArgument(name: name, kind: .integer, description: description, isRequired: false)
    }

    static func boolean(_ name: String, _ description: String) -> ToolArgument {
        ToolArgument(name: name, kind: .boolean, description: description, isRequired: false)
    }
}

/// Typed access to the arguments of one tool call.
struct ToolArguments: Sendable {
    private let values: [String: Value]

    init(_ values: [String: Value]) {
        self.values = values
    }

    /// A required string argument.
    ///
    /// - Throws: ``ASCError/invalidConfiguration(reason:)`` when absent or empty, so a
    ///   caller that forgot an argument gets a usable message instead of a decode error.
    func require(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw ASCError.invalidConfiguration(reason: "Missing required argument '\(key)'.")
        }
        return value
    }

    /// An optional string argument. Empty strings read as absent.
    func string(_ key: String) -> String? {
        guard let value = values[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// An optional integer argument, falling back to `defaultValue`.
    ///
    /// The value is clamped to `1...max`: a host that sends `limit: 0` would otherwise
    /// get an empty list back with no explanation, and one that sends `limit: 100000`
    /// would walk every page of a collection and burn the hourly rate limit.
    func int(_ key: String, default defaultValue: Int, max maxValue: Int = 200) -> Int {
        guard let raw = values[key]?.intValue else { return defaultValue }
        return min(max(raw, 1), maxValue)
    }

    /// An optional boolean argument. Tolerates the string `"true"`, which some MCP
    /// hosts send for a boolean field.
    func bool(_ key: String) -> Bool {
        values[key]?.boolValue ?? (values[key]?.stringValue.map { $0.lowercased() == "true" } ?? false)
    }
}

/// A tool's schema and its implementation, declared together.
///
/// Keeping the two in one value means the catalog the server advertises and the
/// dispatcher that serves it cannot drift apart — there is no separate `switch` to
/// forget a case in, and the JSON Schema is derived from the same argument list the
/// handler reads.
struct ToolSpec: Sendable {
    typealias Handler = @Sendable (ToolArguments, CITools.ClientProvider) async throws -> CallTool.Result

    let name: String
    let description: String
    let arguments: [ToolArgument]
    /// Whether the tool only reads. Advertised to the host as `readOnlyHint`, which is
    /// what lets a client auto-approve a call instead of prompting for every lookup —
    /// worth carrying, since an investigation is dozens of calls deep.
    let isReadOnly: Bool
    let handler: Handler

    init(
        name: String,
        description: String,
        arguments: [ToolArgument] = [],
        isReadOnly: Bool = true,
        handler: @escaping Handler
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.isReadOnly = isReadOnly
        self.handler = handler
    }

    /// The MCP tool advertised to the host, with its schema generated from ``arguments``.
    var tool: Tool {
        var properties: [String: Value] = [:]
        for argument in arguments {
            properties[argument.name] = .object([
                "type": .string(argument.kind.rawValue),
                "description": .string(argument.description),
            ])
        }

        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        let required = arguments.filter(\.isRequired).map { Value.string($0.name) }
        if !required.isEmpty {
            schema["required"] = .array(required)
        }

        return Tool(
            name: name,
            description: description,
            inputSchema: .object(schema),
            annotations: .init(
                readOnlyHint: isReadOnly,
                destructiveHint: !isReadOnly,
                idempotentHint: isReadOnly,
                // Every tool talks to Apple's servers, whose state this server does not own.
                openWorldHint: true
            )
        )
    }
}
