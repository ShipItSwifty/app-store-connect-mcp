import Foundation

// MARK: - CI log parsing
//
// Xcode Cloud exposes build logs as downloadable artifacts (`fileType == "LOG_BUNDLE"`,
// and per-action text logs). The App Store Connect API does not pre-parse them, so an
// agent trying to reason about *why* a build failed has to read raw `xcodebuild` output.
//
// `CILogParser` turns that raw text into a small set of structured findings — compiler
// errors, linker failures, code-signing problems, and per-test failures — so the agent
// (or the MCP tool) gets the signal without the noise.

/// A single structured finding extracted from a raw CI log.
public struct CILogFinding: Codable, Sendable, Equatable {
    /// The kind of problem this line represents.
    public enum Kind: String, Codable, Sendable {
        case compileError
        case compileWarning
        case linkerError
        case codeSigningError
        case testFailure
        case fatalError
        case scriptError
        case generic
    }

    /// The classified kind of finding.
    public let kind: Kind
    /// The human-readable message (without the `file:line:` prefix, when one was present).
    public let message: String
    /// Source file path, if the finding referenced one.
    public let path: String?
    /// 1-based line number, if the finding referenced one.
    public let line: Int?
    /// The raw log line the finding was extracted from.
    public let rawLine: String

    /// Creates a `CILogFinding`.
    public init(kind: Kind, message: String, path: String? = nil, line: Int? = nil, rawLine: String) {
        self.kind = kind
        self.message = message
        self.path = path
        self.line = line
        self.rawLine = rawLine
    }
}

/// The result of parsing a raw CI log.
public struct CILogAnalysis: Codable, Sendable, Equatable {
    /// Every finding, in the order it appeared in the log.
    public let findings: [CILogFinding]
    /// Number of log lines scanned.
    public let linesScanned: Int

    /// Creates a `CILogAnalysis`.
    public init(findings: [CILogFinding], linesScanned: Int) {
        self.findings = findings
        self.linesScanned = linesScanned
    }

    /// Findings that represent a hard failure (errors, linker/signing failures, crashed tests).
    public var errors: [CILogFinding] {
        findings.filter { $0.kind != .compileWarning && $0.kind != .generic }
    }

    /// A compact, deduplicated summary suitable for embedding in an agent prompt.
    public var summary: String {
        guard !findings.isEmpty else { return "No errors or test failures found in \(linesScanned) log lines." }
        var seen = Set<String>()
        var lines: [String] = []
        for finding in findings where finding.kind != .compileWarning {
            let location = finding.path.map { path in
                finding.line.map { "\(path):\($0)" } ?? path
            }
            let rendered = location.map { "\($0): \(finding.message)" } ?? finding.message
            if seen.insert(rendered).inserted {
                lines.append("[\(finding.kind.rawValue)] \(rendered)")
            }
        }
        if lines.isEmpty { return "Only warnings found in \(linesScanned) log lines." }
        return lines.joined(separator: "\n")
    }
}

/// Parses raw `xcodebuild` / Xcode Cloud log text into structured findings.
///
/// The parser is deliberately line-oriented and dependency-free so it runs identically
/// on macOS and Linux. It errs toward recall: a noisy match is better than a missed
/// build break, and callers can filter by ``CILogFinding/Kind``.
public struct CILogParser: Sendable {
    /// The maximum number of findings to return. Protects against pathological logs
    /// (e.g. thousands of repeated warnings) blowing up an agent's context window.
    public let findingLimit: Int

    /// Creates a `CILogParser`.
    ///
    /// - Parameter findingLimit: Maximum findings to collect. Defaults to 200.
    public init(findingLimit: Int = 200) {
        self.findingLimit = max(1, findingLimit)
    }

    /// Parse a raw log string.
    public func parse(_ text: String) -> CILogAnalysis {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var findings: [CILogFinding] = []

        for rawSlice in rawLines {
            if findings.count >= findingLimit { break }
            let raw = String(rawSlice)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let finding = Self.classify(trimmed) else { continue }
            findings.append(finding)
        }

        return CILogAnalysis(findings: findings, linesScanned: rawLines.count)
    }

    // MARK: - Line classification

    static func classify(_ line: String) -> CILogFinding? {
        let lower = line.lowercased()

        // 1. `file.swift:12:5: error: message` / `... warning: message`
        if let located = parseLocated(line) {
            return located
        }

        // 2. XCTest failure:
        //    "Test Case '-[MyTests testThing]' failed (0.003 seconds)."
        //    "/path/File.swift:42: error: -[MyTests testThing] : XCTAssertEqual failed: ..."
        if line.contains("Test Case '") && lower.contains("' failed") {
            return CILogFinding(kind: .testFailure, message: line, rawLine: line)
        }

        // 3. Swift Testing failure:
        //    "✘ Test "does the thing" recorded an issue at File.swift:12:3: ..."
        if line.contains("recorded an issue") || (line.hasPrefix("✘") || line.hasPrefix("✗")) {
            return CILogFinding(kind: .testFailure, message: line, rawLine: line)
        }

        // 4. Linker errors.
        if lower.contains("undefined symbol") || lower.contains("duplicate symbol")
            || lower.contains("ld: error") || lower.contains("linker command failed")
        {
            return CILogFinding(kind: .linkerError, message: line, rawLine: line)
        }

        // 5. Code signing.
        if lower.contains("code signing") || lower.contains("code sign error")
            || lower.contains("no signing certificate")
            || lower.contains("provisioning profile")
                && lower.contains("error")
        {
            return CILogFinding(kind: .codeSigningError, message: line, rawLine: line)
        }

        // 6. Fatal errors / crashes.
        if lower.hasPrefix("fatal error:") || lower.contains("fatal error:")
            || lower.contains("segmentation fault") || lower.contains("terminating with uncaught exception")
        {
            return CILogFinding(kind: .fatalError, message: line, rawLine: line)
        }

        // 7. Shell / run-script phase failures.
        if lower.contains("command phasescriptexecution failed")
            || (lower.hasPrefix("+ ") == false && lower.contains("error:") && lower.contains("script"))
        {
            return CILogFinding(kind: .scriptError, message: line, rawLine: line)
        }

        // 8. Generic "error:" not otherwise classified (kept out of `errors`, still surfaced).
        if lower.contains("error:") {
            return CILogFinding(kind: .compileError, message: line, rawLine: line)
        }

        return nil
    }

    /// Parses a `path:line:col: error|warning|note: message` clang/swift diagnostic.
    static func parseLocated(_ line: String) -> CILogFinding? {
        // Find the first `: error:` / `: warning:` marker.
        let markers: [(String, CILogFinding.Kind)] = [
            (": error:", .compileError),
            (": warning:", .compileWarning),
            (": fatal error:", .fatalError),
        ]

        for (marker, kind) in markers {
            guard let markerRange = line.range(of: marker) else { continue }

            let prefix = String(line[line.startIndex..<markerRange.lowerBound])
            let message = String(line[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Only treat this as a located diagnostic if the prefix actually looks like a
            // file reference (`path/to/File.swift:12:3`). A bare tool name — `clang: error:`,
            // `ld: error:`, `swift: error:` — is not located; let the keyword rules classify it.
            let looksLikePath = prefix.contains("/") || prefix.contains(".")
            let hasLineNumber = prefix.split(separator: ":").dropFirst().contains { Int($0.trimmingCharacters(in: .whitespaces)) != nil }
            guard looksLikePath || hasLineNumber else { return nil }

            // prefix looks like "Sources/App/Foo.swift:42:9" or "Sources/App/Foo.swift:42"
            let components = prefix.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count >= 2 else {
                return CILogFinding(kind: kind, message: message.isEmpty ? line : message, rawLine: line)
            }

            // Last numeric components are line[:col]; everything before is the path.
            var path = String(components[0])
            var lineNumber: Int?

            if components.count >= 2, let n = Int(components[1].trimmingCharacters(in: .whitespaces)) {
                lineNumber = n
                // Re-join in case the path itself contained a colon (rare, but drive letters etc.)
                path = components[0..<1].joined(separator: ":")
            } else {
                path = prefix
            }

            let cleanPath = path.trimmingCharacters(in: .whitespaces)
            return CILogFinding(
                kind: kind,
                message: message.isEmpty ? line : message,
                path: cleanPath.isEmpty ? nil : cleanPath,
                line: lineNumber,
                rawLine: line
            )
        }

        return nil
    }
}
