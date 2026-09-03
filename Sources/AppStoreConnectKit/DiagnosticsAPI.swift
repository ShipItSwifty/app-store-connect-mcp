import Foundation

// MARK: - Production diagnostics read API
//
// What real devices report, as opposed to what CI reports: crash/hang/disk-write
// signatures for a build, the call stacks behind them, the crash log attached to a
// TestFlight crash submission, and the Xcode Organizer power-and-performance metrics.
//
// Two of these endpoints (`diagnosticSignatures/{id}/logs` and `perfPowerMetrics`)
// answer with Apple's own envelope rather than the JSON:API `{"data": …}` one, so
// they decode into their response type directly.

extension AppStoreConnectClient {
    /// Lists the diagnostic signatures reported against a build.
    ///
    /// A signature is one *class* of problem — a hang at a particular stack, say —
    /// rolled up across every device that hit it, ranked by ``ASCDiagnosticSignature/Attributes/weight``.
    ///
    /// - Parameters:
    ///   - buildID: The build id (from ``AppStoreConnectClient/builds(appID:version:preReleaseVersion:processingState:limit:)``).
    ///   - diagnosticType: Optional `filter[diagnosticType]`: `DISK_WRITES`, `HANGS`, `LAUNCHES`.
    ///   - limit: Maximum signatures to return across all pages.
    public func diagnosticSignatures(
        buildID: String,
        diagnosticType: String? = nil,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCDiagnosticSignature> {
        var query: [String: String] = [:]
        if let diagnosticType { query["filter[diagnosticType]"] = diagnosticType }
        return try await getAll("/v1/builds/\(buildID)/diagnosticSignatures", query: query, limit: limit)
    }

    /// Fetches the raw logs behind a diagnostic signature.
    ///
    /// Prefer ``diagnosticLogSummary(signatureID:limit:maxFramesPerReport:)`` unless you
    /// need the whole call-stack tree: one signature's logs routinely run to megabytes.
    public func diagnosticLogs(signatureID: String, limit: Int = 10) async throws -> DiagnosticLogsResponse {
        try await get("/v1/diagnosticSignatures/\(signatureID)/logs", query: ["limit": String(limit)])
    }

    /// Fetches a signature's logs and reduces them to the frames Apple blames.
    ///
    /// - Parameters:
    ///   - signatureID: The signature id (from ``diagnosticSignatures(buildID:diagnosticType:limit:)``).
    ///   - limit: Maximum device reports to fetch.
    ///   - maxFramesPerReport: Cap on frames kept per report, highest sample count first.
    public func diagnosticLogSummary(
        signatureID: String,
        limit: Int = 10,
        maxFramesPerReport: Int = 25
    ) async throws -> DiagnosticLogSummary {
        let response = try await diagnosticLogs(signatureID: signatureID, limit: limit)
        return DiagnosticLogSummary.from(response, maxFramesPerReport: maxFramesPerReport)
    }

    /// Downloads the crash log attached to a TestFlight crash feedback submission.
    ///
    /// ``betaFeedback(appID:kind:buildID:deviceModel:osVersion:limit:)`` reports *that*
    /// a tester crashed and on what device; this returns the symbolicated crash log
    /// itself, which is the part worth reading.
    ///
    /// - Returns: The log text, or `nil` when Apple has no log for the submission yet
    ///   (crash logs are attached asynchronously and are not always available).
    public func betaCrashLog(feedbackID: String) async throws -> String? {
        let response: ASCResponse<BetaCrashLogResource> = try await get(
            "/v1/betaFeedbackCrashSubmissions/\(feedbackID)/crashLog"
        )
        let text = response.data.attributes?.logText
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Fetches the raw power-and-performance metrics for an app.
    ///
    /// Prefer ``perfPowerMetricsSummary(appID:platform:metricType:deviceType:)`` unless
    /// you need every percentile of every version: the raw payload runs to thousands of
    /// data points.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - platform: `filter[platform]` — `IOS`, `MAC_OS`, `TV_OS`, `WATCH_OS`.
    ///   - metricType: `filter[metricType]` — `DISK`, `HANG`, `BATTERY`, `LAUNCH`,
    ///     `MEMORY`, `ANIMATION`, `TERMINATION`.
    ///   - deviceType: `filter[deviceType]` — e.g. `all_iPhones`.
    public func perfPowerMetrics(
        appID: String,
        platform: String? = nil,
        metricType: String? = nil,
        deviceType: String? = nil
    ) async throws -> PerfPowerMetricsResponse {
        var query: [String: String] = [:]
        if let platform { query["filter[platform]"] = platform }
        if let metricType { query["filter[metricType]"] = metricType }
        if let deviceType { query["filter[deviceType]"] = deviceType }
        return try await get("/v1/apps/\(appID)/perfPowerMetrics", query: query)
    }

    /// Fetches power-and-performance metrics and reduces them to Apple's flagged
    /// regressions plus the newest measurement of each metric.
    public func perfPowerMetricsSummary(
        appID: String,
        platform: String? = nil,
        metricType: String? = nil,
        deviceType: String? = nil
    ) async throws -> PerfPowerMetricsSummary {
        let response = try await perfPowerMetrics(
            appID: appID,
            platform: platform,
            metricType: metricType,
            deviceType: deviceType
        )
        return PerfPowerMetricsSummary.from(response)
    }
}

/// The `betaCrashLogs` resource — a single `logText` attribute.
struct BetaCrashLogResource: Codable, Sendable {
    let id: String
    let attributes: Attributes?

    struct Attributes: Codable, Sendable {
        let logText: String?
    }
}

// MARK: - Normalization

extension DiagnosticLogSummary {
    /// Flattens each report's call-stack tree into the frames Apple blames, falling
    /// back to the most-sampled frames when nothing is marked.
    ///
    /// A tree with no blame frame still has to say *something* useful, and the deepest
    /// heavily-sampled frames are what a reader would pick out by hand anyway.
    static func from(_ response: DiagnosticLogsResponse, maxFramesPerReport: Int) -> DiagnosticLogSummary {
        let product = response.productData?.first
        let reports = (product?.diagnosticLogs ?? []).map { log -> Report in
            var collected: [(frame: Report.Frame, isBlame: Bool)] = []
            var total = 0

            func walk(_ frames: [DiagnosticLogsResponse.ProductData.Log.CallStackTree.Frame], depth: Int) {
                for frame in frames {
                    total += 1
                    // Frames with no symbol are system noise once the blame frames are
                    // in hand; keeping them would crowd out the ones worth reading.
                    if frame.symbolName != nil || frame.isBlameFrame == true {
                        collected.append(
                            (
                                Report.Frame(
                                    symbolName: frame.symbolName,
                                    binaryName: frame.binaryName,
                                    fileName: frame.fileName,
                                    lineNumber: frame.lineNumber,
                                    sampleCount: frame.sampleCount,
                                    depth: depth
                                ),
                                frame.isBlameFrame == true
                            )
                        )
                    }
                    walk(frame.subFrames ?? [], depth: depth + 1)
                }
            }

            for tree in log.callStackTree ?? [] {
                for stack in tree.callStacks ?? [] {
                    walk(stack.callStackRootFrames ?? [], depth: 0)
                }
            }

            let blamed = collected.filter(\.isBlame)
            let chosen = blamed.isEmpty ? collected : blamed
            let ranked =
                chosen
                .sorted { ($0.frame.sampleCount ?? 0) > ($1.frame.sampleCount ?? 0) }
                .prefix(maxFramesPerReport)
                .map(\.frame)

            let metadata = log.diagnosticMetaData
            return Report(
                appVersion: metadata?.appVersion,
                buildVersion: metadata?.buildVersion,
                osVersion: metadata?.osVersion,
                deviceType: metadata?.deviceType,
                event: metadata?.event,
                eventDetail: metadata?.eventDetail,
                writesCaused: metadata?.writesCaused,
                blameFrames: Array(ranked),
                totalFrames: total
            )
        }
        return DiagnosticLogSummary(signatureID: product?.signatureId, reports: reports)
    }
}

extension PerfPowerMetricsSummary {
    /// Keeps Apple's regressions plus the newest point of each metric series.
    static func from(_ response: PerfPowerMetricsResponse) -> PerfPowerMetricsSummary {
        let regressions = (response.insights?.regressions ?? []).map { insight in
            Regression(
                metric: insight.metric,
                category: insight.metricCategory,
                summary: insight.summaryString,
                highImpact: insight.highImpact,
                latestVersion: insight.latestVersion,
                // The worst-hit device/percentile is the one that decides whether this
                // is worth acting on; the rest of the populations are detail.
                worstDeltaPercentage: (insight.populations ?? [])
                    .compactMap(\.deltaPercentage)
                    .max(by: { abs($0) < abs($1) })
            )
        }

        var metrics: [Metric] = []
        for product in response.productData ?? [] {
            for category in product.metricCategories ?? [] {
                for metric in category.metrics ?? [] {
                    for dataset in metric.datasets ?? [] {
                        // Apple returns points oldest-first; the last one is the version
                        // a caller is asking about.
                        guard let point = dataset.points?.last else { continue }
                        metrics.append(
                            Metric(
                                category: category.identifier,
                                metric: metric.identifier,
                                platform: product.platform,
                                device: dataset.filterCriteria?.deviceMarketingName
                                    ?? dataset.filterCriteria?.device,
                                percentile: dataset.filterCriteria?.percentile,
                                version: point.version,
                                value: point.value,
                                unit: metric.unit?.displayName ?? metric.unit?.identifier,
                                goal: point.goal
                            )
                        )
                    }
                }
            }
        }
        return PerfPowerMetricsSummary(regressions: regressions, metrics: metrics)
    }
}
