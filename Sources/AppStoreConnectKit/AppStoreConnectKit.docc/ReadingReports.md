# Read analytics and sales reports

Retrieve tabular reporting data and handle reports that are not yet available.

## Overview

Analytics follows a request, report, instance, and downloadable segment. The
convenience API chooses the newest matching instance and reads its first segment:

```swift
let analytics = try await client.latestAnalyticsReport(
    appID: "1234567890", category: "APP_USAGE", maxRows: 100
)
if let analytics {
    print(analytics.table)
}
```

A `nil` result means there is no active request, matching report, or available
data. It does not mean the app had zero activity. Creating an analytics report
request is a separate write operation. For complete multi-segment data, use
`analyticsReportSegments` and download each segment; the convenience method reads
only the first one, with rows capped by `maxRows`.

### Sales and trends

```swift
let sales = try await client.salesReport(
    vendorNumber: "YOUR_VENDOR_NUMBER", reportDate: "2026-10-01", maxRows: 100
)
if let sales {
    print(sales)
}
```

The vendor number comes from App Store Connect's financial reporting settings;
the API cannot discover it. Reporting permissions differ from Xcode Cloud
permissions, so a key that reads CI builds can still receive `403` here.
Sales reports return `nil` for Apple's `404` response, including dates with no
report or data that has not been processed yet.

``ReportTable`` parses the downloaded text. Analytics segments use comma-separated
data and sales reports use tab-separated data; gzip payloads are inflated before
parsing. Row limits keep responses manageable and should be raised when the
caller needs more data.
