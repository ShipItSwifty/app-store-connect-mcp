import Foundation
import MCP
import Testing

@testable import AppStoreConnectKit
@testable import AppStoreConnectMCPServer

/// Covers the reporting tools: vendor-number resolution, the "nothing set up yet"
/// answers, and that a report reaches the agent as a bounded table.
@Suite("ReportingTools (MCP)", .serialized)
struct ReportingToolsTests {
    private func text(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case .text(let value, _, _) = content { return value }
        }
        return ""
    }

    private func call(
        _ name: String,
        _ arguments: [String: Value],
        _ responses: [MCPMockURLProtocol.Canned]
    ) async throws -> CallTool.Result {
        let client = makeMockMCPClient(responses)
        return try await CITools.dispatch(name: name, arguments: arguments, makeClient: { client })
    }

    @Test("The reporting tools are advertised in the one catalog, read-only")
    func advertised() {
        let byName = Dictionary(uniqueKeysWithValues: CITools.all.map { ($0.name, $0) })
        for expected in ["asc_list_analytics_reports", "asc_get_analytics_report", "asc_sales_report"] {
            #expect(byName[expected]?.annotations.readOnlyHint == true, "\(expected) missing or not read-only")
        }
    }

    @Test("asc_list_analytics_reports lists each request with the reports under it")
    func listAnalyticsReports() async throws {
        let result = try await call(
            "asc_list_analytics_reports",
            ["app_id": .string("123")],
            [
                jsonCanned(
                    ["data": [["id": "req-1", "attributes": ["accessType": "ONGOING"]]]],
                    pathContains: "apps/123/analyticsReportRequests"
                ),
                jsonCanned(
                    ["data": [["id": "rep-1", "attributes": ["name": "Installs", "category": "APP_USAGE"]]]],
                    pathContains: "req-1/reports"
                ),
            ]
        )
        let payload = text(result)
        #expect(payload.contains("Installs"))
        #expect(payload.contains("APP_USAGE"))
    }

    @Test("asc_get_analytics_report reports 'not found' when nothing is set up yet")
    func analyticsNotConfigured() async throws {
        let result = try await call(
            "asc_get_analytics_report",
            ["app_id": .string("123")],
            [jsonCanned(["data": []])]
        )
        #expect(text(result).contains("\"found\" : false"))
        #expect(result.isError != true, "an app nobody has enabled analytics for is not a failure")
    }

    @Test("asc_sales_report says how to supply a vendor number instead of failing opaquely")
    func salesReportNeedsVendorNumber() async throws {
        do {
            _ = try await call("asc_sales_report", ["report_date": .string("2026-01-01")], [])
            Issue.record("expected a configuration error")
        } catch let error as ASCError {
            #expect(error.localizedDescription.contains("ASC_VENDOR_NUMBER"))
        }
    }

    @Test("The vendor number falls back to the environment")
    func vendorNumberFromEnvironment() {
        #expect(ReportingTools.environmentVendorNumber(["ASC_VENDOR_NUMBER": "80000123"]) == "80000123")
        #expect(ReportingTools.environmentVendorNumber(["ASC_VENDOR_NUMBER": ""]) == nil)
        #expect(ReportingTools.environmentVendorNumber([:]) == nil)
    }

    @Test("asc_sales_report returns a bounded table and reports a missing date as found:false")
    func salesReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("report.tsv")
        try Data("Provider\tUnits\nAPPLE\t42\n".utf8).write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-c", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let gzippedTSV = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let found = try await call(
            "asc_sales_report",
            ["report_date": .string("2026-01-01"), "vendor_number": .string("80000123")],
            [.init(statusCode: 200, body: gzippedTSV)]
        )
        #expect(text(found).contains("\"found\" : true"))
        #expect(text(found).contains("APPLE"))

        let missing = try await call(
            "asc_sales_report",
            ["report_date": .string("2026-01-02"), "vendor_number": .string("80000123")],
            [jsonCanned(["errors": [["detail": "no sales"]]], statusCode: 404)]
        )
        #expect(text(missing).contains("\"found\" : false"))
    }
}
