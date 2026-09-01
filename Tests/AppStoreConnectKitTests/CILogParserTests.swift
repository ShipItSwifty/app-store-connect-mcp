import Foundation
import Testing

@testable import AppStoreConnectKit

@Suite("CILogParser")
struct CILogParserTests {
    @Test("Parses a located Swift compiler error into path + line")
    func locatedCompileError() {
        let log = """
            Compiling module App
            /Users/ci/App/Sources/App/Foo.swift:42:9: error: cannot find 'bar' in scope
            ** BUILD FAILED **
            """
        let analysis = CILogParser().parse(log)
        let finding = try! #require(analysis.findings.first { $0.kind == .compileError })
        #expect(finding.path == "/Users/ci/App/Sources/App/Foo.swift")
        #expect(finding.line == 42)
        #expect(finding.message == "cannot find 'bar' in scope")
        #expect(analysis.linesScanned == 3)
    }

    @Test("Classifies a located warning separately from errors")
    func locatedWarning() {
        let analysis = CILogParser().parse("Sources/App/Bar.swift:7:1: warning: variable 'x' was never used")
        let finding = try! #require(analysis.findings.first)
        #expect(finding.kind == .compileWarning)
        #expect(finding.line == 7)
        #expect(analysis.errors.isEmpty)
    }

    @Test("Detects XCTest and Swift Testing failures")
    func testFailures() {
        let log = """
            Test Case '-[AppTests.MathTests testAddition]' failed (0.004 seconds).
            ✘ Test "addition works" recorded an issue at MathTests.swift:12:3: Expectation failed
            """
        let analysis = CILogParser().parse(log)
        #expect(analysis.findings.filter { $0.kind == .testFailure }.count == 2)
    }

    @Test("Detects linker, code-signing, and fatal errors")
    func otherFailureKinds() {
        let log = """
            Undefined symbol: _OBJC_CLASS_$_Missing
            Code Signing Error: No signing certificate "iOS Distribution" found
            fatal error: unexpectedly found nil while unwrapping an Optional value
            """
        let analysis = CILogParser().parse(log)
        #expect(analysis.findings.contains { $0.kind == .linkerError })
        #expect(analysis.findings.contains { $0.kind == .codeSigningError })
        #expect(analysis.findings.contains { $0.kind == .fatalError })
    }

    @Test("Informational code-signing output is not reported as an error")
    func benignCodeSigningLinesAreIgnored() {
        let log = """
            Code Signing Identity = Apple Development
            Provisioning profile "Example Dev" (matched)
            """
        let analysis = CILogParser().parse(log)
        #expect(analysis.findings.isEmpty)
    }

    @Test("An unattributed error line is classified as generic, and still counts as an error")
    func unattributedErrorIsGeneric() {
        let analysis = CILogParser().parse("xcodebuild: error: something went sideways")
        let finding = try! #require(analysis.findings.first)
        #expect(finding.kind == .generic)
        #expect(analysis.errors.count == 1)
    }

    @Test("A real ld failure is still a linker error")
    func realLinkerErrorStillMatches() {
        #expect(CILogParser().parse("ld: error: too many personality routines").findings.first?.kind == .linkerError)
        #expect(
            CILogParser().parse("  ld: error: framework not found Foo").findings.first?.kind == .linkerError
        )
    }

    @Test("Clean log yields no findings and a friendly summary")
    func cleanLog() {
        let analysis = CILogParser().parse("Building...\n** BUILD SUCCEEDED **\n")
        #expect(analysis.findings.isEmpty)
        #expect(analysis.summary.contains("No errors"))
    }

    @Test("findingLimit caps the number of findings")
    func findingLimitCap() {
        let noisy = Array(repeating: "Sources/A.swift:1:1: error: boom", count: 50).joined(separator: "\n")
        let analysis = CILogParser(findingLimit: 10).parse(noisy)
        #expect(analysis.findings.count == 10)
        #expect(analysis.linesScanned == 50)
    }

    @Test("summary dedupes repeated identical findings and skips warnings")
    func summaryDedupes() {
        let log = """
            Sources/A.swift:1:1: error: boom
            Sources/A.swift:1:1: error: boom
            Sources/A.swift:2:1: warning: meh
            """
        let summary = CILogParser().parse(log).summary
        #expect(summary.components(separatedBy: "\n").count == 1)
        #expect(!summary.contains("meh"))
    }

    @Test("Located error without a line number still classifies")
    func errorWithoutLineNumber() {
        let analysis = CILogParser().parse("clang: error: linker command failed with exit code 1")
        let finding = try! #require(analysis.findings.first)
        #expect(finding.kind == .linkerError)
    }

    @Test("CILogFinding and CILogAnalysis round-trip through Codable")
    func codableRoundTrip() throws {
        let original = CILogParser().parse("Sources/A.swift:3:2: error: nope\nTest Case '-[T x]' failed (0s).")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CILogAnalysis.self, from: data)
        #expect(decoded == original)
    }
}
