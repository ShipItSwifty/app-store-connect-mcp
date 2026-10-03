# Investigate an Xcode Cloud failure

Find the latest failed build and inspect issues, tests, and log findings.

## Overview

Start with the App Store Connect app ID returned by `client.apps()`:

```swift
let latest = try await client.ciLatestFailureReport(appID: "1234567890")
if let report = latest.report {
    for action in report.failedActions {
        print(action.name ?? action.id, action.issues, action.failedTests)
    }
}
```

``CILatestFailure/found`` is `false` when no failed run is found in the scanned
workflows. This is a normal result. Pass a workflow ID instead of an app ID to
narrow the investigation to one workflow.

### Include log evidence

```swift
if let runID = latest.buildRunID {
    let enriched = try await client.ciFailureReportWithLogs(buildRunID: runID)
    print(enriched.logFindingsByAction)
    print(enriched.skippedArtifacts)
}
```

``CIFailureReportWithLogs`` combines API issues with findings parsed from text
logs and ZIP log bundles. Downloads use short-lived signed URLs without the API
authorization header. Fetch them shortly after listing artifacts.

Binary artifacts, expired URLs, and unreadable logs are recorded in
`skippedArtifacts`; an otherwise successful report can therefore contain partial
log evidence. Review those notes before concluding that an action had no log
errors. To parse text already on disk, use ``CILogParser`` directly.
