import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Where a tool result's `structuredContent` departs from the tool's advertised
/// `outputSchema`, as readable paths. Empty means it conforms.
///
/// Understands the subset of JSON Schema ``OutputSchemas`` uses — `type`,
/// `properties`, `required`, `items` — which is enough to catch a renamed field, a
/// type change, or a required field that went optional. A host that validates would
/// reject exactly these.
func schemaViolations(_ result: CallTool.Result, tool name: String) -> [String] {
    guard let schema = CITools.specs(writesEnabled: true).first(where: { $0.name == name })?.outputSchema else {
        return ["\(name) declares no outputSchema"]
    }
    guard let structured = result.structuredContent else {
        return ["\(name) returned no structuredContent"]
    }
    return schemaViolations(structured, against: schema, at: "$")
}

func schemaViolations(_ value: Value, against schema: Value, at path: String) -> [String] {
    guard case .object(let rules) = schema else { return [] }
    var problems: [String] = []

    if case .string(let type)? = rules["type"], !value.matches(jsonType: type) {
        return ["\(path): expected \(type), got \(value)"]
    }

    if case .object(let fields) = value {
        if case .array(let required)? = rules["required"] {
            for case .string(let key) in required where fields[key] == nil {
                problems.append("\(path).\(key): required but missing")
            }
        }
        if case .object(let properties)? = rules["properties"] {
            for (key, propertySchema) in properties {
                if let field = fields[key] {
                    problems += schemaViolations(field, against: propertySchema, at: "\(path).\(key)")
                }
            }
        }
    }

    if case .array(let elements) = value, let itemSchema = rules["items"] {
        for (index, element) in elements.enumerated() {
            problems += schemaViolations(element, against: itemSchema, at: "\(path)[\(index)]")
        }
    }
    return problems
}

extension Value {
    fileprivate func matches(jsonType type: String) -> Bool {
        switch (type, self) {
        case ("object", .object), ("array", .array), ("boolean", .bool), ("string", .string), ("string", .data):
            return true
        case ("integer", .int), ("number", .int), ("number", .double):
            return true
        case ("integer", .double(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }
}

/// Covers the `outputSchema` / `structuredContent` pairing: which tools declare one,
/// what the result carries, and that the rate-limit heads-up doesn't drop it.
@Suite("Structured tool output", .serialized)
struct StructuredOutputTests {
    private let schemaTools: Set = [
        "asc_ci_failure_report",
        "asc_ci_failure_report_with_logs",
        "asc_ci_latest_failure",
        "asc_submission_status",
        "asc_rate_limit_status",
    ]

    @Test("Exactly the report tools advertise an object outputSchema")
    func reportToolsAdvertiseSchemas() {
        for tool in CITools.specs(writesEnabled: true).map(\.tool) {
            if schemaTools.contains(tool.name) {
                guard case .object(let schema)? = tool.outputSchema else {
                    Issue.record("\(tool.name) should advertise an outputSchema")
                    continue
                }
                #expect(schema["type"] == .string("object"), "\(tool.name): outputSchema must describe an object")
            } else {
                #expect(tool.outputSchema == nil, "\(tool.name) has an unexpected outputSchema")
            }
        }
    }

    @Test("A tool without a schema returns text only")
    func plainToolsHaveNoStructuredContent() async throws {
        let client = makeMockMCPClient([jsonCanned(["data": [["id": "prod-1", "attributes": ["name": "App"]]]])])
        let result = try await CITools.call(name: "asc_ci_list_products", arguments: [:]) { client }
        #expect(result.structuredContent == nil)
    }

    @Test("structuredContent mirrors the text block and conforms to the schema")
    func structuredMirrorsText() async throws {
        let client = makeMockMCPClient([jsonCanned(["data": []])])
        let result = try await CITools.call(name: "asc_rate_limit_status", arguments: [:]) { client }

        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("expected a text block")
            return
        }
        let decoded = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(result.structuredContent == decoded)
        #expect(schemaViolations(result, tool: "asc_rate_limit_status") == [])
    }

    @Test("The rate-limit heads-up keeps the structured payload")
    func headsUpKeepsStructuredContent() async throws {
        let client = makeMockMCPClient([
            jsonCanned(["data": []], headers: ["X-Rate-Limit": "user-hour-lim:1000;user-hour-rem:50"])
        ])
        let result = try await CITools.call(name: "asc_rate_limit_status", arguments: [:]) { client }

        #expect(result.content.count == 2, "expected the payload plus the heads-up")
        #expect(schemaViolations(result, tool: "asc_rate_limit_status") == [])
    }

    @Test("Only a JSON object becomes structuredContent, and errors stay as they are")
    func onlyObjectsAreStructured() {
        let array = CallTool.Result(content: [.plainText("[1,2]")], isError: false)
        #expect(array.addingStructuredContent().structuredContent == nil)

        let prose = CallTool.Result(content: [.plainText("not json")], isError: false)
        #expect(prose.addingStructuredContent().structuredContent == nil)

        let failure = CallTool.Result(content: [.plainText("{\"a\":1}")], isError: true)
        #expect(failure.addingStructuredContent().structuredContent == nil)

        let object = CallTool.Result(content: [.plainText("{\"a\":\"x\"}")], isError: false)
        #expect(object.addingStructuredContent().structuredContent == .object(["a": .string("x")]))
    }

    @Test("The validator itself catches a missing required field and a wrong type")
    func validatorCatchesDrift() {
        let schema = OutputSchemas.object(["n": OutputSchemas.integer, "s": OutputSchemas.string], required: ["n"])
        #expect(schemaViolations(.object(["n": .int(1), "s": .string("x")]), against: schema, at: "$") == [])
        #expect(schemaViolations(.object(["s": .string("x")]), against: schema, at: "$") == ["$.n: required but missing"])
        #expect(schemaViolations(.object(["n": .string("1")]), against: schema, at: "$").count == 1)
    }
}
