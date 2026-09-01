import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Artifact download + log analysis
//
// Xcode Cloud artifact `downloadUrl`s are short-lived signed URLs served directly by
// Apple's asset host — they take no `Authorization` header (and reject one). These
// helpers fetch the bytes and, for text-decodable artifacts, run `CILogParser`.

extension AppStoreConnectClient {
    /// Downloads the raw bytes of a CI artifact from its signed `downloadUrl`.
    ///
    /// - Parameter urlString: The `downloadUrl` from a ``CIArtifact``.
    /// - Returns: The artifact's bytes.
    /// - Throws: ``ASCError/apiError(statusCode:body:)`` on a non-2xx response or an unusable URL.
    public func downloadArtifact(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw ASCError.invalidConfiguration(reason: "Invalid artifact download URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ASCError.apiError(statusCode: 0, body: "Invalid response type for artifact download")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ASCError.apiError(
                statusCode: http.statusCode,
                body: "Artifact download failed (\(http.statusCode)) for \(url.lastPathComponent)"
            )
        }
        return data
    }

    /// Downloads a CI artifact and parses it as a text log.
    ///
    /// Binary or non-UTF-8 artifacts (e.g. zipped `LOG_BUNDLE`s, `xcresult` bundles) cannot
    /// be parsed here — this throws ``ASCError/uploadFailed(asset:reason:)`` for those, and the
    /// caller should download and expand them out-of-band.
    ///
    /// - Parameters:
    ///   - urlString: The artifact `downloadUrl`.
    ///   - parser: The parser to use. Defaults to `CILogParser()`.
    /// - Returns: The structured analysis.
    public func analyzeArtifactLog(
        from urlString: String,
        parser: CILogParser = CILogParser()
    ) async throws -> CILogAnalysis {
        let data = try await downloadArtifact(from: urlString)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ASCError.uploadFailed(
                asset: URL(string: urlString)?.lastPathComponent ?? "artifact",
                reason: "Artifact is not UTF-8 text (\(data.count) bytes); expand it out-of-band before analyzing."
            )
        }
        return parser.parse(text)
    }
}

// MARK: - Enriched failure report

/// A ``CIFailureReport`` augmented with parsed findings from each failed action's
/// text log artifacts.
public struct CIFailureReportWithLogs: Codable, Sendable {
    /// The underlying structured failure report.
    public let report: CIFailureReport
    /// Parsed log findings, keyed by build action id.
    public let logFindingsByAction: [String: CILogAnalysis]
    /// Human-readable notes about artifacts that could not be analyzed (binary, expired URL, …).
    public let skippedArtifacts: [String]

    /// Creates a `CIFailureReportWithLogs`.
    public init(
        report: CIFailureReport,
        logFindingsByAction: [String: CILogAnalysis],
        skippedArtifacts: [String]
    ) {
        self.report = report
        self.logFindingsByAction = logFindingsByAction
        self.skippedArtifacts = skippedArtifacts
    }
}

extension AppStoreConnectClient {
    private static let logAnalyzerLogger = Logger.forType(subsystem: "AppStoreConnectKit", AppStoreConnectClient.self)

    /// Builds a ``CIFailureReport`` and additionally downloads + parses every failed
    /// action's text-log artifacts, attaching the structured findings.
    ///
    /// Artifacts that are not UTF-8 text, or whose signed URL has expired, are skipped
    /// and noted in ``CIFailureReportWithLogs/skippedArtifacts`` rather than failing the call.
    ///
    /// - Parameters:
    ///   - buildRunID: The build run id.
    ///   - workflowName: Optional workflow name embedded in the report for context.
    ///   - parser: The log parser to use. Defaults to `CILogParser()`.
    public func ciFailureReportWithLogs(
        buildRunID: String,
        workflowName: String? = nil,
        parser: CILogParser = CILogParser()
    ) async throws -> CIFailureReportWithLogs {
        let report = try await ciFailureReport(buildRunID: buildRunID, workflowName: workflowName)

        var findingsByAction: [String: CILogAnalysis] = [:]
        var skipped: [String] = []

        for action in report.failedActions {
            var merged: [CILogFinding] = []
            var linesScanned = 0
            for artifact in action.artifacts {
                guard let downloadURL = artifact.downloadUrl, !downloadURL.isEmpty else { continue }
                guard Self.looksLikeTextLog(artifact) else {
                    skipped.append(
                        "\(action.name ?? action.id): \(artifact.fileName ?? "artifact") (\(artifact.fileType ?? "unknown type"))")
                    continue
                }
                do {
                    let analysis = try await analyzeArtifactLog(from: downloadURL, parser: parser)
                    merged.append(contentsOf: analysis.findings)
                    linesScanned += analysis.linesScanned
                } catch {
                    skipped.append("\(action.name ?? action.id): \(artifact.fileName ?? "artifact") — \(error.localizedDescription)")
                }
            }
            if !merged.isEmpty || linesScanned > 0 {
                findingsByAction[action.id] = CILogAnalysis(findings: merged, linesScanned: linesScanned)
            }
        }

        return CIFailureReportWithLogs(
            report: report,
            logFindingsByAction: findingsByAction,
            skippedArtifacts: skipped
        )
    }

    /// Heuristic: is this artifact plausibly a plain-text log we can parse in-process?
    static func looksLikeTextLog(_ artifact: CIFailureReport.FailedAction.Artifact) -> Bool {
        let type = (artifact.fileType ?? "").uppercased()
        let name = (artifact.fileName ?? "").lowercased()
        if type.contains("XCRESULT") || name.hasSuffix(".xcresult") { return false }
        if name.hasSuffix(".zip") || name.hasSuffix(".gz") || name.hasSuffix(".ipa") { return false }
        if type.contains("LOG") { return !name.hasSuffix(".zip") }
        if name.hasSuffix(".log") || name.hasSuffix(".txt") { return true }
        // LOG_BUNDLE is usually zipped; treat unknown types conservatively as non-text.
        return false
    }
}
