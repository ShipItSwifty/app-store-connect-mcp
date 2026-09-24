# Swift libraries

## Install (library)

**Requires Swift 6.3+** (macOS 15+ / Linux).

```swift
.package(url: "https://github.com/ShipItSwifty/app-store-connect-mcp.git", from: "0.1.0"),
```

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "AppStoreConnectKit", package: "app-store-connect-mcp"),
])
```

```swift
import AppStoreConnectKit

let client = AppStoreConnectClient(
    credentials: ASCCredentials(keyID: "…", issuerID: "…", privateKeyPEM: pem)
)
let report = try await client.ciFailureReport(buildRunID: "…")
```

### Library API

`AppStoreConnectClient` is an actor that owns JWT minting, rate-limit backoff, and
the REST plumbing. On top of the generic `get` / `post` / `patch` it offers:

| Area | Entry points |
|---|---|
| **Apps & discovery** | `apps(bundleID:name:limit:)`, `app(id:)` |
| **App Store versions** | `appStoreVersions(appID:platform:limit:)`, `appStoreVersionLocalizations(versionID:limit:)` |
| **Builds & TestFlight** | `builds(appID:version:preReleaseVersion:processingState:limit:)`, `buildBetaDetail(buildID:)`, `betaBuildLocalizations(buildID:)`, `betaGroups(appID:)`, `betaTesters(betaGroupID:)`, `betaFeedback(appID:kind:…)` |
| **Customer reviews** | `customerReviews(appID:rating:territory:limit:)` |
| **Review readiness** | `phasedRelease(versionID:)`, `appStoreReviewDetail(versionID:)`, `betaAppReviewDetail(appID:)`, `appInfos(appID:)` |
| **Signing assets** | `certificates(limit:)`, `profiles(state:limit:)`, `signingAssets(withinDays:limit:)` |
| **Reporting** | `analyticsReportRequests(appID:)`, `analyticsReports(requestID:…)`, `analyticsReportInstances(reportID:…)`, `analyticsReportSegments(instanceID:)`, `latestAnalyticsReport(appID:…)`, `salesReport(vendorNumber:reportDate:…)` |
| **Production diagnostics** | `diagnosticSignatures(buildID:diagnosticType:limit:)`, `diagnosticLogs(signatureID:limit:)`, `diagnosticLogSummary(signatureID:…)`, `betaCrashLog(feedbackID:)`, `perfPowerMetrics(appID:…)`, `perfPowerMetricsSummary(appID:…)` |
| **Xcode Cloud (read)** | `ciProducts`, `ciWorkflows`, `ciWorkflow(id:)`, `ciBuildRuns(workflowID:limit:failedOnly:)`, `ciBuildRun(id:)`, `ciBuildActions`, `ciIssues`, `ciTestResults`, `ciArtifacts`, `ciTestPlans(workflowID:)` |
| **Aggregated diagnostics** | `ciFailureReport(buildRunID:workflowName:)`, `ciFailureReportWithLogs(…)`, `ciLatestFailureReport(workflowID:productID:appID:)` |
| **Artifacts & logs** | `downloadArtifact(from:)`, `analyzeArtifactLog(from:parser:)`, `CILogParser` |
| **Release management** | `AppStoreReleaseService` — see below |
| **Review diagnostics** | `AppStoreSubmissionService.status(bundleID:)` |
| **Xcode Cloud (write)** | `startCIBuildRun(workflowID:gitReferenceID:clean:)`, `rerunCIBuildRun(buildRunID:clean:)` |
| **IPA upload** (macOS) | `IPAUploadService.uploadIPA(at:bundleID:credentials:shell:)` |
| **Anything else** | `getRaw(_:query:)` — Apple's JSON verbatim, for resources with no typed model |

#### `AppStoreReleaseService`

Write operations against an app's App Store listing. All three resolve (or create)
the latest `appStoreVersions` record for the bundle id first.

```swift
let service = AppStoreReleaseService(client: client)

// Pull every locale's metadata into <dir>/<locale>/{name,subtitle,description,keywords,release_notes,promotional_text}.txt
try await service.pullMetadata(bundleID: "com.example.app", directory: "./metadata")

// Push those files back up (upserts appInfoLocalizations + appStoreVersionLocalizations).
try await service.pushMetadata(bundleID: "com.example.app", directory: "./metadata") {
    "1.4.0"  // called only if a new App Store version must be created
}

// Set the release type, optionally add a phased release, and create a review submission.
let result = try await service.submitForReview(
    bundleID: "com.example.app",
    automaticRelease: true,
    phasedRelease: false,
    resolveVersionString: { "1.4.0" }
)
```

#### `IPAUploadService` (macOS only)

`/v1/builds` has no `CREATE`, so uploads go through `xcrun altool --upload-app`.
`altool` reads the signing key from a fixed location, so **this service writes your
`.p8` to `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`** (0700 dir, 0600 file)
for the duration of the upload and removes it afterwards — unless a key was already
there, in which case it is left untouched. After `altool` exits, the service extracts
`CFBundleVersion` from the IPA and polls `/v1/builds` until the new build appears.

#### Transient retries

`429` and the occasional bare `5xx` from Apple's edge are retried with exponential
backoff, honouring `Retry-After` (`TransientRetryPolicy`, 3 attempts by default). Only
`GET` is replayed on a `5xx` — a `POST`/`PATCH` may already have been applied
server-side — while a `429`, which Apple refuses before doing any work, is retried on
any method. Pass `retryPolicy: .disabled` to the client initializer to opt out.

#### Pagination

List endpoints return one page at a time. The typed `ci*` helpers use
`getAll(_:query:limit:)`, which follows `links.next` until either the collection is
exhausted or `limit` resources have been collected (page size is capped at Apple's
maximum of 200). If the returned envelope's `links.next` is non-nil, `limit` cut the
walk short and more resources exist.

