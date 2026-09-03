import Foundation

// MARK: - Sales and analytics reporting
//
// The two bulk-data corners of the API. Both answer with gzipped delimited text
// rather than JSON:API resources, and the analytics side is a four-hop walk
// (request → report → instance → segment) before any data exists.
//
// Access here is role-dependent in a way the rest of the API is not: sales and
// finance reports need a key with the Finance or Sales role, which is *not* the Team
// key the `ci*` endpoints require. A 403 here on a key that reads Xcode Cloud fine is
// expected, not a bug.

/// One analytics report request — the standing subscription that produces reports.
public struct ASCAnalyticsReportRequest: Codable, Sendable {
    /// Unique identifier for this request.
    public let id: String
    /// Request attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAnalyticsReportRequest`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an analytics report request.
    public struct Attributes: Codable, Sendable {
        /// `ONGOING` or `ONE_TIME_SNAPSHOT`.
        public let accessType: String?
        /// `true` once Apple stops producing reports because nothing has read them.
        public let stoppedDueToInactivity: Bool?

        /// Creates `ASCAnalyticsReportRequest.Attributes`.
        public init(accessType: String? = nil, stoppedDueToInactivity: Bool? = nil) {
            self.accessType = accessType
            self.stoppedDueToInactivity = stoppedDueToInactivity
        }
    }
}

/// One report available under a request, e.g. `App Store Installations`.
public struct ASCAnalyticsReport: Codable, Sendable {
    /// Unique identifier for this report.
    public let id: String
    /// Report attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAnalyticsReport`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of an analytics report.
    public struct Attributes: Codable, Sendable {
        public let name: String?
        /// `APP_USAGE`, `APP_STORE_ENGAGEMENT`, `COMMERCE`, `FRAMEWORK_USAGE`, `PERFORMANCE`.
        public let category: String?

        /// Creates `ASCAnalyticsReport.Attributes`.
        public init(name: String? = nil, category: String? = nil) {
            self.name = name
            self.category = category
        }
    }
}

/// One processing date of a report, at one granularity.
public struct ASCAnalyticsReportInstance: Codable, Sendable {
    /// Unique identifier for this instance.
    public let id: String
    /// Instance attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAnalyticsReportInstance`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a report instance.
    public struct Attributes: Codable, Sendable {
        /// `DAILY`, `WEEKLY`, or `MONTHLY`.
        public let granularity: String?
        /// The day this instance covers, `YYYY-MM-DD`.
        public let processingDate: String?

        /// Creates `ASCAnalyticsReportInstance.Attributes`.
        public init(granularity: String? = nil, processingDate: String? = nil) {
            self.granularity = granularity
            self.processingDate = processingDate
        }
    }
}

/// One downloadable chunk of a report instance.
public struct ASCAnalyticsReportSegment: Codable, Sendable {
    /// Unique identifier for this segment.
    public let id: String
    /// Segment attributes.
    public let attributes: Attributes?

    /// Creates an `ASCAnalyticsReportSegment`.
    public init(id: String, attributes: Attributes? = nil) {
        self.id = id
        self.attributes = attributes
    }

    /// Attributes of a report segment.
    public struct Attributes: Codable, Sendable {
        /// A time-limited download URL for the gzipped CSV.
        public let url: String?
        public let sizeInBytes: Int?
        public let checksum: String?

        /// Creates `ASCAnalyticsReportSegment.Attributes`.
        public init(url: String? = nil, sizeInBytes: Int? = nil, checksum: String? = nil) {
            self.url = url
            self.sizeInBytes = sizeInBytes
            self.checksum = checksum
        }
    }
}

/// A downloaded report, parsed far enough to be readable: a header row, a bounded
/// number of data rows, and the count of everything that was left behind.
public struct ReportTable: Codable, Sendable {
    /// Column names from the report's first line.
    public let columns: [String]
    /// Data rows, capped at the requested row limit.
    public let rows: [[String]]
    /// Rows in the full report, including the ones not returned.
    public let totalRows: Int
    /// `true` when `rows` is shorter than `totalRows`.
    public let truncated: Bool

    /// Creates a `ReportTable`.
    public init(columns: [String], rows: [[String]], totalRows: Int, truncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.totalRows = totalRows
        self.truncated = truncated
    }

    /// Parses delimited text (Apple uses tab-separated for sales, comma for analytics).
    ///
    /// This is deliberately not a full CSV parser: Apple's report columns are plain
    /// values with no embedded delimiters or quoting, and pretending otherwise would
    /// add a parser nothing here needs.
    public init(text: String, separator: Character, maxRows: Int) {
        var lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            self.init(columns: [], rows: [], totalRows: 0, truncated: false)
            return
        }
        let header = lines.removeFirst().split(separator: separator, omittingEmptySubsequences: false)
        let kept = lines.prefix(max(0, maxRows))
        self.init(
            columns: header.map(String.init),
            rows: kept.map { $0.split(separator: separator, omittingEmptySubsequences: false).map(String.init) },
            totalRows: lines.count,
            truncated: lines.count > kept.count
        )
    }
}

extension AppStoreConnectClient {
    // MARK: - Analytics

    /// Lists the analytics report requests already configured for an app.
    ///
    /// Reports only exist under a request, and a request is created once and then
    /// produces data daily — so a caller checks here before creating another.
    public func analyticsReportRequests(
        appID: String,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCAnalyticsReportRequest> {
        try await getAll("/v1/apps/\(appID)/analyticsReportRequests", limit: limit)
    }

    /// Creates an analytics report request for an app.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - accessType: `ONGOING` (daily, from the request date forward) or
    ///     `ONE_TIME_SNAPSHOT` (a one-off backfill).
    /// - Note: This is a write. Apple starts producing data the following day, so the
    ///   reports of a fresh request are empty for a while.
    public func createAnalyticsReportRequest(
        appID: String,
        accessType: String = "ONGOING"
    ) async throws -> ASCAnalyticsReportRequest {
        let body = AnalyticsReportRequestBody(
            data: .init(
                type: "analyticsReportRequests",
                attributes: .init(accessType: accessType),
                relationships: .init(app: .init(data: .init(type: "apps", id: appID)))
            )
        )
        let response: ASCResponse<ASCAnalyticsReportRequest> = try await post("/v1/analyticsReportRequests", body: body)
        return response.data
    }

    /// Lists the reports available under a request.
    ///
    /// - Parameters:
    ///   - requestID: The analytics report request id.
    ///   - category: Optional `filter[category]` — `APP_USAGE`, `APP_STORE_ENGAGEMENT`,
    ///     `COMMERCE`, `FRAMEWORK_USAGE`, `PERFORMANCE`.
    ///   - name: Optional `filter[name]`, an exact report name.
    public func analyticsReports(
        requestID: String,
        category: String? = nil,
        name: String? = nil,
        limit: Int = 200
    ) async throws -> ASCListResponse<ASCAnalyticsReport> {
        var query: [String: String] = [:]
        if let category { query["filter[category]"] = category }
        if let name { query["filter[name]"] = name }
        return try await getAll("/v1/analyticsReportRequests/\(requestID)/reports", query: query, limit: limit)
    }

    /// Lists the processing dates available for a report.
    public func analyticsReportInstances(
        reportID: String,
        granularity: String? = nil,
        processingDate: String? = nil,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCAnalyticsReportInstance> {
        var query: [String: String] = [:]
        if let granularity { query["filter[granularity]"] = granularity }
        if let processingDate { query["filter[processingDate]"] = processingDate }
        return try await getAll("/v1/analyticsReports/\(reportID)/instances", query: query, limit: limit)
    }

    /// Lists the downloadable segments of a report instance.
    public func analyticsReportSegments(
        instanceID: String,
        limit: Int = 50
    ) async throws -> ASCListResponse<ASCAnalyticsReportSegment> {
        try await getAll("/v1/analyticsReportInstances/\(instanceID)/segments", limit: limit)
    }

    /// Downloads a report segment and inflates it into a table.
    ///
    /// Segment URLs are signed and short-lived, so fetch them right before use.
    public func downloadAnalyticsSegment(
        url: String,
        maxRows: Int = 200
    ) async throws -> ReportTable {
        let data = try await downloadArtifact(from: url)
        let text = Gzip.looksLikeGzip(data) ? try Gzip.decompressText(data) : String(decoding: data, as: UTF8.self)
        return ReportTable(text: text, separator: ",", maxRows: maxRows)
    }

    /// Walks request → report → newest instance → first segment and returns the data.
    ///
    /// Four round-trips stand between an app id and a single number, and the shape of
    /// the walk never varies, so it is done here rather than by every caller.
    ///
    /// - Parameters:
    ///   - appID: App Store Connect app id.
    ///   - reportName: Exact report name (e.g. `App Store Installations Standard`).
    ///   - category: `filter[category]` used when `reportName` is not given.
    ///   - granularity: `DAILY`, `WEEKLY`, or `MONTHLY`.
    ///   - processingDate: A specific `YYYY-MM-DD`; defaults to the newest available.
    ///   - maxRows: Rows to keep from the segment.
    /// - Returns: The table, or `nil` when the app has no report request, no matching
    ///   report, or no data yet — all normal states rather than failures.
    public func latestAnalyticsReport(
        appID: String,
        reportName: String? = nil,
        category: String? = nil,
        granularity: String = "DAILY",
        processingDate: String? = nil,
        maxRows: Int = 200
    ) async throws -> AnalyticsReportResult? {
        // A request Apple stopped for inactivity still lists, but produces nothing new;
        // prefer a live one and fall back only if that is all there is.
        let requests = try await analyticsReportRequests(appID: appID, limit: 10).data
        guard
            let request = requests.first(where: { ($0.attributes?.stoppedDueToInactivity ?? false) == false })
                ?? requests.first
        else { return nil }

        guard
            let report = try await analyticsReports(
                requestID: request.id,
                category: category,
                name: reportName,
                limit: 200
            ).data.first
        else { return nil }

        let instances = try await analyticsReportInstances(
            reportID: report.id,
            granularity: granularity,
            processingDate: processingDate,
            limit: 200
        ).data
        // Instances arrive newest-last on some tenants and newest-first on others;
        // ordering by the date they carry is the only stable way to pick "latest".
        guard
            let instance = instances.max(by: {
                ($0.attributes?.processingDate ?? "") < ($1.attributes?.processingDate ?? "")
            })
        else { return nil }

        guard let segment = try await analyticsReportSegments(instanceID: instance.id, limit: 10).data.first,
            let url = segment.attributes?.url
        else { return nil }

        return AnalyticsReportResult(
            reportName: report.attributes?.name,
            category: report.attributes?.category,
            granularity: instance.attributes?.granularity,
            processingDate: instance.attributes?.processingDate,
            table: try await downloadAnalyticsSegment(url: url, maxRows: maxRows)
        )
    }

    // MARK: - Sales and trends

    /// Downloads a sales and trends report as a table.
    ///
    /// - Parameters:
    ///   - vendorNumber: The vendor number from App Store Connect's Payments and
    ///     Financial Reports. Required by Apple and not discoverable through this API.
    ///   - reportDate: `YYYY-MM-DD` (daily), `YYYY-MM-DD` of a Sunday (weekly),
    ///     `YYYY-MM` (monthly), or `YYYY` (yearly).
    ///   - frequency: `DAILY`, `WEEKLY`, `MONTHLY`, or `YEARLY`.
    ///   - reportType: `SALES`, `SUBSCRIPTION`, `SUBSCRIPTION_EVENT`, `SUBSCRIBER`, …
    ///   - reportSubType: `SUMMARY`, `DETAILED`, or `OPT_IN`.
    ///   - version: Report version — `1_0` for sales, `1_2`/`1_3` for subscriptions.
    ///   - maxRows: Rows to keep.
    /// - Returns: The table, or `nil` when Apple has no report for that date (a 404,
    ///   which is the normal answer for a day with no sales or one not yet processed).
    /// - Note: Needs a key with the Finance or Sales role — *not* the Team key the
    ///   Xcode Cloud endpoints require.
    public func salesReport(
        vendorNumber: String,
        reportDate: String,
        frequency: String = "DAILY",
        reportType: String = "SALES",
        reportSubType: String = "SUMMARY",
        version: String? = nil,
        maxRows: Int = 200
    ) async throws -> ReportTable? {
        var query: [String: String] = [
            "filter[vendorNumber]": vendorNumber,
            "filter[reportDate]": reportDate,
            "filter[frequency]": frequency,
            "filter[reportType]": reportType,
            "filter[reportSubType]": reportSubType,
        ]
        if let version { query["filter[version]"] = version }

        do {
            let data = try await getRaw("/v1/salesReports", query: query)
            let text =
                Gzip.looksLikeGzip(data) ? try Gzip.decompressText(data) : String(decoding: data, as: UTF8.self)
            return ReportTable(text: text, separator: "\t", maxRows: maxRows)
        } catch let error as ASCError {
            if case .apiError(let statusCode, _) = error, statusCode == 404 { return nil }
            throw error
        }
    }
}

/// One analytics report, resolved down to its data.
public struct AnalyticsReportResult: Codable, Sendable {
    public let reportName: String?
    public let category: String?
    public let granularity: String?
    public let processingDate: String?
    public let table: ReportTable

    /// Creates an `AnalyticsReportResult`.
    public init(
        reportName: String?,
        category: String?,
        granularity: String?,
        processingDate: String?,
        table: ReportTable
    ) {
        self.reportName = reportName
        self.category = category
        self.granularity = granularity
        self.processingDate = processingDate
        self.table = table
    }
}

/// `POST /v1/analyticsReportRequests` body.
private struct AnalyticsReportRequestBody: Encodable, Sendable {
    let data: Data

    struct Data: Encodable, Sendable {
        let type: String
        let attributes: Attributes
        let relationships: Relationships

        struct Attributes: Encodable, Sendable {
            let accessType: String
        }

        struct Relationships: Encodable, Sendable {
            let app: Relationship

            struct Relationship: Encodable, Sendable {
                let data: Identifier

                struct Identifier: Encodable, Sendable {
                    let type: String
                    let id: String
                }
            }
        }
    }
}
