import Foundation
import Testing

@testable import AppStoreConnectKit

/// Covers the reporting endpoints: the four-hop analytics walk, the gzipped payloads,
/// and the table parsing that bounds what a caller gets back.
@Suite("Reporting API")
struct ReportingAPITests {
    /// A real gzip member, so the download path is exercised end to end.
    private func gzipped(_ text: String) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("report")
        try Data(text.utf8).write(to: source)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-c", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    @Test("ReportTable keeps the header, caps the rows, and reports the true total")
    func tableParsing() {
        let text = "Date\tUnits\n2026-01-01\t10\n2026-01-02\t20\n2026-01-03\t30\n"
        let table = ReportTable(text: text, separator: "\t", maxRows: 2)
        #expect(table.columns == ["Date", "Units"])
        #expect(table.rows == [["2026-01-01", "10"], ["2026-01-02", "20"]])
        #expect(table.totalRows == 3, "the count is of the whole report, not of what was kept")
        #expect(table.truncated)

        let complete = ReportTable(text: text, separator: "\t", maxRows: 10)
        #expect(!complete.truncated)
        #expect(complete.rows.count == 3)

        let empty = ReportTable(text: "", separator: "\t", maxRows: 10)
        #expect(empty.columns.isEmpty)
        #expect(empty.totalRows == 0)

        // A header with no data rows is a valid, empty report.
        let headerOnly = ReportTable(text: "Date\tUnits\n", separator: "\t", maxRows: 10)
        #expect(headerOnly.columns.count == 2)
        #expect(headerOnly.rows.isEmpty)
    }

    @Test("latestAnalyticsReport() walks request → report → newest instance → segment")
    func analyticsWalk() async throws {
        let csv = "Date,Installs\n2026-01-02,900\n2026-01-02,100\n"
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json(["data": [["id": "req-1", "attributes": ["accessType": "ONGOING"]]]]),
                .json(["data": [["id": "rep-1", "attributes": ["name": "Installs", "category": "APP_USAGE"]]]]),
                .json([
                    "data": [
                        ["id": "inst-1", "attributes": ["granularity": "DAILY", "processingDate": "2026-01-01"]],
                        ["id": "inst-2", "attributes": ["granularity": "DAILY", "processingDate": "2026-01-02"]],
                    ]
                ]),
                .json(["data": [["id": "seg-1", "attributes": ["url": "https://example.com/seg.csv.gz"]]]]),
                .response(statusCode: 200, headers: [:], body: try gzipped(csv)),
            ]
        )

        let result = try #require(try await client.latestAnalyticsReport(appID: "123", reportName: "Installs"))
        #expect(result.reportName == "Installs")
        // Newest by the date each instance carries, not by position in the page.
        #expect(result.processingDate == "2026-01-02")
        #expect(result.table.columns == ["Date", "Installs"])
        #expect(result.table.rows.count == 2)

        #expect(observed.value[2].contains("/v1/analyticsReports/rep-1/instances"))
        #expect(observed.value[3].contains("/v1/analyticsReportInstances/inst-2/segments"))
    }

    @Test("latestAnalyticsReport() prefers a request Apple hasn't stopped for inactivity")
    func analyticsSkipsStoppedRequest() async throws {
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [
                .json([
                    "data": [
                        ["id": "req-dead", "attributes": ["stoppedDueToInactivity": true]],
                        ["id": "req-live", "attributes": ["stoppedDueToInactivity": false]],
                    ]
                ]),
                .json(["data": []]),
            ]
        )

        #expect(try await client.latestAnalyticsReport(appID: "123") == nil)
        #expect(observed.value[1].contains("/v1/analyticsReportRequests/req-live/reports"))
    }

    @Test("An app with no analytics set up returns nil rather than failing")
    func analyticsNotConfigured() async throws {
        let client = makeClient(responses: [.json(["data": []])])
        #expect(try await client.latestAnalyticsReport(appID: "123") == nil)
    }

    @Test("createAnalyticsReportRequest() sends the camelCase JSON:API body Apple expects")
    func createRequestBody() async throws {
        let bodies = LockedBox<[[String: Any]]>([])
        let client = makeClientRecording(
            observedBodies: bodies,
            responses: [.json(["data": ["id": "req-1", "attributes": ["accessType": "ONGOING"]]])]
        )

        let created = try await client.createAnalyticsReportRequest(appID: "123", accessType: "ONGOING")
        #expect(created.id == "req-1")

        let data = try #require(bodies.value.first?["data"] as? [String: Any])
        #expect(data["type"] as? String == "analyticsReportRequests")
        #expect((data["attributes"] as? [String: Any])?["accessType"] as? String == "ONGOING")
        let app = ((data["relationships"] as? [String: Any])?["app"] as? [String: Any])?["data"] as? [String: Any]
        #expect(app?["type"] as? String == "apps")
        #expect(app?["id"] as? String == "123")
    }

    @Test("salesReport() sends every required filter and inflates the gzipped TSV")
    func salesReport() async throws {
        let tsv = "Provider\tUnits\nAPPLE\t42\n"
        let observed = LockedBox<[String]>([])
        let client = makeClientRecording(
            observedURLs: observed,
            responses: [.response(statusCode: 200, headers: [:], body: try gzipped(tsv))]
        )

        let table = try #require(
            try await client.salesReport(vendorNumber: "80000123", reportDate: "2026-01-01", version: "1_0"))
        #expect(table.columns == ["Provider", "Units"])
        #expect(table.rows == [["APPLE", "42"]])

        let query = URLComponents(string: observed.value[0])?.queryItems ?? []
        let sent = query.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        #expect(sent["filter[vendorNumber]"] == "80000123")
        #expect(sent["filter[reportDate]"] == "2026-01-01")
        #expect(sent["filter[frequency]"] == "DAILY")
        #expect(sent["filter[reportType]"] == "SALES")
        #expect(sent["filter[reportSubType]"] == "SUMMARY")
        #expect(sent["filter[version]"] == "1_0")
    }

    @Test("A date Apple has no sales report for reads as nil, not as an error")
    func salesReportMissingDate() async throws {
        let client = makeClient(responses: [
            .error(statusCode: 404, body: #"{"errors":[{"detail":"There were no sales for this date."}]}"#)
        ])
        #expect(try await client.salesReport(vendorNumber: "80000123", reportDate: "2026-01-01") == nil)
    }

    @Test("A 403 from a key without the Finance role still surfaces")
    func salesReportForbidden() async throws {
        // Sales reports need a Finance/Sales key, not the Team key the ci* endpoints
        // want; swallowing that would look like "no data" instead of "wrong key".
        let client = makeClient(responses: [.error(statusCode: 403, body: "forbidden")])
        await #expect(throws: ASCError.self) {
            _ = try await client.salesReport(vendorNumber: "80000123", reportDate: "2026-01-01")
        }
    }

    @Test("A report served without gzip is still readable")
    func plainTextReport() async throws {
        let client = makeClient(responses: [
            .response(statusCode: 200, headers: [:], body: Data("Provider\tUnits\nAPPLE\t7\n".utf8))
        ])
        let table = try #require(try await client.salesReport(vendorNumber: "1", reportDate: "2026-01-01"))
        #expect(table.rows == [["APPLE", "7"]])
    }
}
