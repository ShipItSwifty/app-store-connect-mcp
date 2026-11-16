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
    /// A zipped `LOG_BUNDLE` is expanded in-process and every text file inside it
    /// (the `xcodebuild` output *and* the stdout/stderr of custom CI scripts such as
    /// `ci_post_xcodebuild.sh`) is parsed and merged. Genuinely binary artifacts
    /// (`xcresult` bundles, products) still throw ``ASCError/uploadFailed(asset:reason:)``.
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
        let name = URL(string: urlString)?.lastPathComponent ?? "artifact"

        if ZipArchive.looksLikeZip(data) {
            let bundle = Self.analyzeLogBundle(data, parser: parser)
            guard let analysis = bundle.analysis else {
                throw ASCError.uploadFailed(
                    asset: name,
                    reason: "Log bundle held no readable text logs"
                        + (bundle.skipped.isEmpty ? "." : ": \(bundle.skipped.joined(separator: "; "))")
                )
            }
            return analysis
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw ASCError.uploadFailed(
                asset: name,
                reason: "Artifact is not UTF-8 text or a ZIP (\(data.count) bytes); expand it out-of-band before analyzing."
            )
        }
        return parser.parse(text)
    }

    /// Expands a `LOG_BUNDLE` ZIP in memory and parses every text file inside it,
    /// merging the findings. Returns `nil` analysis when the archive yielded no
    /// readable text, along with notes about what was skipped.
    static func analyzeLogBundle(
        _ data: Data,
        parser: CILogParser
    ) -> (analysis: CILogAnalysis?, skipped: [String]) {
        let extraction: (entries: [ZipEntry], skipped: [String])
        do {
            extraction = try ZipArchive.entries(in: data, where: Self.isLikelyTextLogEntry)
        } catch {
            return (nil, ["log bundle could not be expanded: \(error)"])
        }

        var findings: [CILogFinding] = []
        var linesScanned = 0
        var skipped = extraction.skipped

        for entry in extraction.entries.sorted(by: { $0.path < $1.path }) {
            guard let text = String(data: entry.data, encoding: .utf8) else {
                skipped.append("\(entry.path): not UTF-8 text")
                continue
            }
            let parsed = parser.parse(text)
            findings.append(contentsOf: parsed.findings)
            linesScanned += parsed.linesScanned
        }

        guard linesScanned > 0 || !findings.isEmpty else { return (nil, skipped) }
        return (CILogAnalysis(findings: findings, linesScanned: linesScanned), skipped)
    }

    /// Denylist heuristic for ZIP entries worth parsing as text. Errs toward recall
    /// (mirrors ``CILogParser``): anything not obviously binary is worth a scan, and
    /// per-line classification keeps the noise bounded.
    static func isLikelyTextLogEntry(_ path: String) -> Bool {
        let lower = path.lowercased()
        let binarySuffixes = [
            ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".gz", ".tar", ".xcresult",
            ".plist", ".a", ".o", ".dylib", ".framework", ".ipa", ".app", ".dsym", ".car",
            ".nib", ".bin", ".db", ".sqlite", ".mobileprovision", ".p12", ".cer", ".xcarchive",
        ]
        if binarySuffixes.contains(where: lower.hasSuffix) { return false }
        return true
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

        // Artifact downloads go to Apple's signed asset host, not the rate-limited API,
        // so every artifact of every failed action is fetched concurrently. The flat job
        // list keeps action and artifact order, so findings and notes come out in the
        // same order the sequential loop produced.
        let jobs = report.failedActions.enumerated().flatMap { index, action in
            action.artifacts.compactMap { artifact -> ArtifactJob? in
                guard let url = artifact.downloadUrl, !url.isEmpty else { return nil }
                return ArtifactJob(actionIndex: index, label: action.name ?? action.id, artifact: artifact, url: url)
            }
        }
        let outcomes = try await jobs.concurrentMap(maxConcurrency: Self.artifactDownloadLimit) { job in
            await self.analyzeArtifact(job, parser: parser)
        }

        var findingsByAction: [String: CILogAnalysis] = [:]
        var skipped: [String] = []

        for (index, action) in report.failedActions.enumerated() {
            var merged: [CILogFinding] = []
            var linesScanned = 0
            for (job, outcome) in zip(jobs, outcomes) where job.actionIndex == index {
                if let analysis = outcome.analysis {
                    merged.append(contentsOf: analysis.findings)
                    linesScanned += analysis.linesScanned
                }
                skipped.append(contentsOf: outcome.skipped)
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

    /// Artifacts downloaded at once. Lower than ``ascFanOutLimit`` because each one is
    /// held in memory whole while it is inflated and parsed.
    static let artifactDownloadLimit = 3

    /// One artifact to fetch for ``ciFailureReportWithLogs(buildRunID:workflowName:parser:)``.
    struct ArtifactJob: Sendable {
        let actionIndex: Int
        let label: String
        let artifact: CIFailureReport.FailedAction.Artifact
        let url: String
    }

    /// What one artifact contributed: parsed findings, and notes on what was skipped.
    struct ArtifactOutcome: Sendable {
        var analysis: CILogAnalysis?
        var skipped: [String] = []
    }

    /// Downloads and parses one artifact. Never throws: a failure becomes a skip note so
    /// one expired URL does not sink the whole report.
    func analyzeArtifact(_ job: ArtifactJob, parser: CILogParser) async -> ArtifactOutcome {
        let artifactName = job.artifact.fileName ?? "artifact"
        if Self.looksLikeTextLog(job.artifact) {
            do {
                return ArtifactOutcome(analysis: try await analyzeArtifactLog(from: job.url, parser: parser))
            } catch {
                return ArtifactOutcome(skipped: ["\(job.label): \(artifactName) — \(error.localizedDescription)"])
            }
        }
        if Self.looksLikeLogBundle(job.artifact) {
            do {
                let bundle = Self.analyzeLogBundle(try await downloadArtifact(from: job.url), parser: parser)
                return ArtifactOutcome(
                    analysis: bundle.analysis,
                    skipped: bundle.skipped.map { "\(job.label): \(artifactName) → \($0)" }
                )
            } catch {
                return ArtifactOutcome(skipped: ["\(job.label): \(artifactName) — \(error.localizedDescription)"])
            }
        }
        return ArtifactOutcome(
            skipped: ["\(job.label): \(artifactName) (\(job.artifact.fileType ?? "unknown type"))"]
        )
    }

    /// Heuristic: is this artifact plausibly a plain-text log we can parse in-process?
    static func looksLikeTextLog(_ artifact: CIFailureReport.FailedAction.Artifact) -> Bool {
        let type = (artifact.fileType ?? "").uppercased()
        let name = (artifact.fileName ?? "").lowercased()
        if type.contains("XCRESULT") || name.hasSuffix(".xcresult") { return false }
        if name.hasSuffix(".zip") || name.hasSuffix(".gz") || name.hasSuffix(".ipa") { return false }
        if type.contains("LOG") && !type.contains("BUNDLE") { return !name.hasSuffix(".zip") }
        if name.hasSuffix(".log") || name.hasSuffix(".txt") { return true }
        // LOG_BUNDLE is usually zipped; treat unknown types conservatively as non-text.
        return false
    }

    /// Heuristic: is this artifact a zipped `LOG_BUNDLE` we should expand and parse
    /// file-by-file (this is where custom CI-script output lives)?
    static func looksLikeLogBundle(_ artifact: CIFailureReport.FailedAction.Artifact) -> Bool {
        let type = (artifact.fileType ?? "").uppercased()
        let name = (artifact.fileName ?? "").lowercased()
        if type.contains("XCRESULT") || name.hasSuffix(".xcresult") { return false }
        if type.contains("LOG_BUNDLE") || type.contains("LOGBUNDLE") { return true }
        if type.contains("LOG") && (name.hasSuffix(".zip") || name.hasSuffix(".gz")) { return true }
        return false
    }
}
