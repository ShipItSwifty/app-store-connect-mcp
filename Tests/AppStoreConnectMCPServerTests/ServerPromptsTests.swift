import Foundation
import MCP
import Testing

@testable import AppStoreConnectMCPServer

/// Covers the server's prompts and `initialize` instructions: that they expand, that
/// they reject bad input usefully, and that every tool they tell a model to call is
/// one this server actually advertises.
@Suite("ServerPrompts")
struct ServerPromptsTests {
    /// Every tool name either catalog can advertise, writes included.
    private let toolNames = Set(CITools.specs(writesEnabled: true).map(\.name))
    private let readOnlyToolNames = Set(CITools.specs(writesEnabled: false).map(\.name))

    private func text(_ result: GetPrompt.Result) -> String {
        result.messages.compactMap { message -> String? in
            if case .text(let value) = message.content { return value }
            return nil
        }.joined(separator: "\n")
    }

    /// The `asc_…` tool names mentioned in a block of text.
    private func mentionedTools(in text: String) throws -> Set<String> {
        let pattern = try Regex("asc_[a-z0-9_]+")
        return Set(text.matches(of: pattern).map { String(text[$0.range]) })
    }

    /// Arguments that satisfy every prompt's required fields.
    private let fullArguments = [
        "bundle_id": "com.example.app",
        "app_id": "123",
        "build_run_id": "run-1",
        "version": "42",
        "build_id": "build-1",
    ]

    @Test("Prompt names are unique and the advertised list matches the specs")
    func catalogIsConsistent() {
        let names = ServerPrompts.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names == ServerPrompts.specs.map(\.name))
        for prompt in ServerPrompts.all {
            #expect(prompt.title?.isEmpty == false, "\(prompt.name) needs a title")
            #expect(prompt.description?.isEmpty == false, "\(prompt.name) needs a description")
        }
    }

    @Test("Every prompt expands, and only names read-only tools this server advertises")
    func promptsReferenceRealReadOnlyTools() throws {
        for spec in ServerPrompts.specs {
            for arguments in [fullArguments, ["bundle_id": "com.example.app"]] {
                let body = text(try ServerPrompts.get(name: spec.name, arguments: arguments))
                let mentioned = try mentionedTools(in: body)
                #expect(!mentioned.isEmpty, "\(spec.name) should name the tools to call")
                #expect(mentioned.isSubset(of: readOnlyToolNames), "\(spec.name) names \(mentioned.subtracting(readOnlyToolNames))")
            }
        }
    }

    @Test("The server instructions only name tools this server advertises")
    func instructionsReferenceRealTools() throws {
        let mentioned = try mentionedTools(in: ServerInstructions.text)
        #expect(!mentioned.isEmpty)
        #expect(mentioned.isSubset(of: toolNames), "unknown: \(mentioned.subtracting(toolNames))")
        for spec in ServerPrompts.specs {
            #expect(ServerInstructions.text.contains(spec.name), "instructions should list prompt \(spec.name)")
        }
    }

    @Test("Arguments are interpolated into the expanded prompt")
    func argumentsAreInterpolated() throws {
        let body = text(try ServerPrompts.get(name: "diagnose_review", arguments: ["bundle_id": "com.example.app"]))
        #expect(body.contains("\"com.example.app\""))

        let run = text(try ServerPrompts.get(name: "triage_ci_failure", arguments: ["build_run_id": "run-9"]))
        #expect(run.contains("\"run-9\""))
        #expect(!run.contains("asc_ci_latest_failure with app_id"))

        let byApp = text(try ServerPrompts.get(name: "triage_ci_failure", arguments: ["app_id": "123"]))
        #expect(byApp.contains("asc_ci_latest_failure with app_id \"123\""))
    }

    @Test("A missing required argument is an invalid-params error naming it")
    func missingRequiredArgumentThrows() {
        #expect(throws: MCPError.invalidParams("Prompt 'diagnose_review' needs the 'bundle_id' argument.")) {
            try ServerPrompts.get(name: "diagnose_review", arguments: [:])
        }
        // A blank form field counts as missing, not as a bundle id of "".
        #expect(throws: MCPError.self) {
            try ServerPrompts.get(name: "diagnose_review", arguments: ["bundle_id": "  "])
        }
    }

    @Test("An unknown prompt is an invalid-params error")
    func unknownPromptThrows() {
        #expect(throws: MCPError.invalidParams("Unknown prompt: nope")) {
            try ServerPrompts.get(name: "nope", arguments: [:])
        }
    }
}
