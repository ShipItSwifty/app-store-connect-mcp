import AppStoreConnectKit
import Foundation
import MCP

/// Tools for the two bulk-data corners of the API: App Store analytics (installs,
/// impressions, sessions, crashes) and sales and trends reports.
///
/// Both come back as gzipped delimited text, and both are returned here as a bounded
/// table — columns, a capped number of rows, and the true row count — because a
/// full report is millions of rows and an agent needs the shape and a sample, not
/// the file.
///
/// Part of the single catalog; see ``CITools/specs``.
enum ReportingTools {
    /// Rows returned unless the caller asks for fewer. High enough to see a pattern,
    /// low enough not to bury the rest of the conversation.
    private static let defaultRowLimit = 100

    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "asc_list_analytics_reports",
            description: """
                List the App Store analytics reports available for an app: the report \
                requests configured, and under them the report names and categories \
                (APP_USAGE, APP_STORE_ENGAGEMENT, COMMERCE, FRAMEWORK_USAGE, PERFORMANCE). \
                Reports only exist under a request, and data starts the day after a request \
                is created — {"requests": []} means nobody has set one up yet, which \
                asc_create_analytics_report_request fixes. Pass either app_id or bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("category", "Filter reports by category."),
                .integer("limit", "Max reports to return per request (default 200)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await AppStoreTools.resolveAppID(args, client: client)
            let requests = try await client.analyticsReportRequests(appID: appID).data

            var described: [AnalyticsRequestSummary] = []
            for request in requests {
                let reports = try await client.analyticsReports(
                    requestID: request.id,
                    category: args.string("category"),
                    limit: args.int("limit", default: 200)
                ).data
                described.append(AnalyticsRequestSummary(request: request, reports: reports))
            }
            return try json(AnalyticsCatalog(appID: appID, requests: described))
        },

        ToolSpec(
            name: "asc_get_analytics_report",
            description: """
                Fetch the data of one App Store analytics report: resolves the app's report \
                request, finds the report by name (or by category), takes the newest \
                processing date at the requested granularity, downloads the segment and \
                inflates it. Returns the column names, up to 'max_rows' rows, and the total \
                row count. Returns {"found": false} when the app has no report request, no \
                matching report, or no data yet — all normal states. Pass either app_id or \
                bundle_id.
                """,
            arguments: [
                .string("app_id", "App Store Connect app id (or pass bundle_id)."),
                .string("bundle_id", "Bundle identifier, resolved to an app id."),
                .string("report_name", "Exact report name, e.g. 'App Store Installations Standard'."),
                .string("category", "Category to pick a report from when report_name is omitted."),
                .string("granularity", "DAILY (default), WEEKLY, or MONTHLY."),
                .string("processing_date", "A specific YYYY-MM-DD. Defaults to the newest available."),
                .integer("max_rows", "Max data rows to return (default 100)."),
            ]
        ) { args, makeClient in
            let client = try makeClient()
            let appID = try await AppStoreTools.resolveAppID(args, client: client)
            let result = try await client.latestAnalyticsReport(
                appID: appID,
                reportName: args.string("report_name"),
                category: args.string("category"),
                granularity: args.string("granularity") ?? "DAILY",
                processingDate: args.string("processing_date"),
                maxRows: args.int("max_rows", default: defaultRowLimit, max: 1000)
            )
            guard let result else { return try json(AnalyticsReportPayload(found: false, report: nil)) }
            return try json(AnalyticsReportPayload(found: true, report: result))
        },

        ToolSpec(
            name: "asc_sales_report",
            description: """
                Download a Sales and Trends report (units, proceeds, subscriptions) as a \
                table. Needs the vendor number from App Store Connect's Payments and \
                Financial Reports — Apple requires it and does not expose it through this \
                API; it can also come from the ASC_VENDOR_NUMBER environment variable. \
                Returns {"found": false} when Apple has no report for that date, which is \
                the normal answer for a day with no sales or one not yet processed. \
                NOTE: this endpoint needs an API key with the Finance or Sales role — a Team \
                key that reads Xcode Cloud fine will get a 403 here.
                """,
            arguments: [
                .string("report_date", "YYYY-MM-DD (daily), a Sunday (weekly), YYYY-MM (monthly), or YYYY.", required: true),
                .string("vendor_number", "Vendor number. Defaults to $ASC_VENDOR_NUMBER."),
                .string("frequency", "DAILY (default), WEEKLY, MONTHLY, or YEARLY."),
                .string("report_type", "SALES (default), SUBSCRIPTION, SUBSCRIPTION_EVENT, SUBSCRIBER, …"),
                .string("report_sub_type", "SUMMARY (default), DETAILED, or OPT_IN."),
                .string("version", "Report version, e.g. 1_0 for SALES or 1_3 for SUBSCRIPTION."),
                .integer("max_rows", "Max data rows to return (default 100)."),
            ]
        ) { args, makeClient in
            guard let vendorNumber = args.string("vendor_number") ?? environmentVendorNumber() else {
                throw ASCError.invalidConfiguration(
                    reason: """
                        Missing vendor number. Pass 'vendor_number', or set ASC_VENDOR_NUMBER. \
                        Find it in App Store Connect under Payments and Financial Reports.
                        """
                )
            }
            let table = try await makeClient().salesReport(
                vendorNumber: vendorNumber,
                reportDate: args.require("report_date"),
                frequency: args.string("frequency") ?? "DAILY",
                reportType: args.string("report_type") ?? "SALES",
                reportSubType: args.string("report_sub_type") ?? "SUMMARY",
                version: args.string("version"),
                maxRows: args.int("max_rows", default: defaultRowLimit, max: 1000)
            )
            guard let table else { return try json(SalesReportPayload(found: false, table: nil)) }
            return try json(SalesReportPayload(found: true, table: table))
        },
    ]

    // MARK: - Payloads

    private struct AnalyticsCatalog: Encodable {
        let appID: String
        let requests: [AnalyticsRequestSummary]
    }

    private struct AnalyticsRequestSummary: Encodable {
        let request: ASCAnalyticsReportRequest
        let reports: [ASCAnalyticsReport]
    }

    private struct AnalyticsReportPayload: Encodable {
        let found: Bool
        let report: AnalyticsReportResult?
    }

    private struct SalesReportPayload: Encodable {
        let found: Bool
        let table: ReportTable?
    }

    // MARK: - Helpers

    /// The vendor number from the environment, so a host can configure it once
    /// alongside the credentials instead of passing it on every call.
    static func environmentVendorNumber(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment["ASC_VENDOR_NUMBER"], !value.isEmpty else { return nil }
        return value
    }

    private static func json<T: Encodable>(_ value: T) throws -> CallTool.Result {
        try CITools.json(value)
    }
}
