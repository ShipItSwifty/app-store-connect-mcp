# app-store-connect-mcp

A reusable Swift client for the **App Store Connect API** — including the **Xcode Cloud**
(`ci*`) resource family — plus an **MCP server** that lets an AI agent investigate *what
broke in CI*.

Two products, both public-facing:

| Product | Platforms | Use it for |
|---|---|---|
| `AppStoreConnectKit` (library) | macOS, Linux | JWT auth, rate limiting, the generic REST client, App Store + TestFlight DTOs, and the typed Xcode Cloud read API (`ciProducts` → `ciWorkflows` → `ciBuildRuns` → `ciBuildActions` → `ciIssues` / `ciTestResults` / `ciArtifacts`). |
| `AppStoreConnectUploadKit` (library) | macOS only | `IPAUploadService` — orchestrates `xcrun altool --upload-app` and resolves the resulting build id. |
| `app-store-connect-mcp` (executable) | macOS, Linux | An MCP (Model Context Protocol) server exposing the Xcode Cloud read API as tools. |

> `AppStoreConnectKit` is consumed by [ShipItSwifty](https://github.com/maniramezan/ShipItSwifty)
> as its App Store Connect layer.

📖 **[API documentation](https://maniramezan.github.io/app-store-connect-mcp/)** (DocC, published from `main`).

## Install (library)

**Requires Swift 6.3+** (macOS 15+ / Linux).

```swift
.package(url: "https://github.com/maniramezan/app-store-connect-mcp.git", from: "0.1.0"),
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
| **Xcode Cloud (read)** | `ciProducts`, `ciWorkflows`, `ciWorkflow(id:)`, `ciBuildRuns(workflowID:limit:failedOnly:)`, `ciBuildRun(id:)`, `ciBuildActions`, `ciIssues`, `ciTestResults`, `ciArtifacts`, `ciTestPlans(workflowID:)` |
| **Aggregated diagnostics** | `ciFailureReport(buildRunID:workflowName:)`, `ciFailureReportWithLogs(…)`, `ciLatestFailureReport(workflowID:productID:appID:)` |
| **Artifacts & logs** | `downloadArtifact(from:)`, `analyzeArtifactLog(from:parser:)`, `CILogParser` |
| **Release management** | `AppStoreReleaseService` — see below |
| **Review diagnostics** | `AppStoreSubmissionService.status(bundleID:)` |
| **IPA upload** (macOS) | `IPAUploadService.uploadIPA(at:bundleID:credentials:shell:)` |

#### `AppStoreReleaseService`

Write operations against an app's App Store listing. All three resolve (or create)
the latest `appStoreVersions` record for the bundle id first.

```swift
let service = AppStoreReleaseService(client: client)

// Pull every locale's metadata into <dir>/<locale>/{name,subtitle,description,keywords,release_notes}.txt
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

#### Pagination

List endpoints return one page at a time. The typed `ci*` helpers use
`getAll(_:query:limit:)`, which follows `links.next` until either the collection is
exhausted or `limit` resources have been collected (page size is capped at Apple's
maximum of 200). If the returned envelope's `links.next` is non-nil, `limit` cut the
walk short and more resources exist.

## MCP server

### Credentials

Set these environment variables (same names as `altool` / Fastlane):

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY` (raw `.p8` PEM contents) **or** `ASC_PRIVATE_KEY_PATH` (path to the file)

#### Key role and JWT audience

- **The API key needs a role that can read Xcode Cloud.** Use a **Team key** with
  **Developer**, **App Manager**, or **Admin** access. A key scoped only to
  Finance / Sales / Customer Support / Marketing gets `403 FORBIDDEN` on the `ci*`
  endpoints (`/v1/ciProducts`, …) even though App Store metadata calls succeed.
- **The signed JWT must carry `aud: "appstoreconnect-v1"`.** `AppStoreConnectKit`
  sets this for you (`JWTGenerator`), along with ES256 signing and a ≤20-minute
  lifetime — the values Apple requires. If you mint tokens yourself for the raw
  `get` client, a missing or wrong `aud` is the usual cause of a `401` with an
  `NOT_AUTHORIZED` / `no valid 'aud'` detail.

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `asc_ci_list_products` | `app_id?` | Xcode Cloud products |
| `asc_ci_list_workflows` | `product_id` | workflows for a product |
| `asc_ci_list_build_runs` | `workflow_id`, `limit?`, `failed_only?` | recent build runs, newest first; `failed_only` over-fetches and returns only `FAILED`/`ERRORED`/`INVALID` runs |
| `asc_ci_list_test_plans` | `workflow_id` | the test plans the workflow runs, flattened from its `TEST` actions (scheme, selection kind, test-plan names) |
| `asc_ci_get_build_run` | `build_run_id` | the run + its actions with issue counts, plus `durationSeconds` for the run and each action |
| `asc_ci_get_issues` | `build_action_id` | errors / warnings / analyzer findings (file + line) |
| `asc_ci_get_test_results` | `build_action_id` | test results |
| `asc_ci_get_artifacts` | `build_action_id` | log bundle / xcresult / product download URLs |
| `asc_ci_failure_report` | `build_run_id`, `workflow_name?` | **one aggregated payload**: every failed action's issues, failed tests, and artifacts, with run + action `durationSeconds` (a value near Xcode Cloud's 120-minute ceiling means a timeout) |
| `asc_ci_failure_report_with_logs` | `build_run_id`, `workflow_name?` | `asc_ci_failure_report` plus each failed action's **text logs downloaded and parsed** into structured findings (compiler / linker / code-signing errors, test failures, with file + line). Zipped `LOG_BUNDLE` artifacts are expanded in-process so custom CI-script output (`ci_post_xcodebuild.sh`, …) is parsed too; genuinely binary artifacts (`xcresult`) are listed under `skippedArtifacts` |
| `asc_ci_latest_failure` | `app_id?` / `product_id?` / `workflow_id?` (one required) | **triage shortcut**: resolves the scope, finds the most recent failed build run, and returns its `asc_ci_failure_report` payload plus the chosen `workflow` + `build_run_id`. Collapses the products → workflows → build runs → run → issues walk into one call; returns `{"found": false}` when nothing has failed |
| `asc_ci_analyze_log` | `text?` **or** `download_url?` | parse raw CI log text (or a downloaded text artifact / zipped log bundle) into structured findings by kind |
| `asc_submission_status` | `bundle_id` | diagnose where the latest App Store version stands in review: version state (`REJECTED`, `METADATA_REJECTED`, `INVALID_BINARY`, `WAITING_FOR_REVIEW`, …), review-submission state, per-item outcomes, whether the developer must act, and a plain-language next step |

The server does no analysis of its own beyond normalization (`CIFailureReport`, `CILatestFailure`, `CILogParser`, `AppStoreSubmissionService`) — the calling agent reasons over the data. When a response leaves the App Store Connect hourly rate limit within 10 points of its throttle threshold, an extra text block is appended warning that further calls may stall.

Each tool is one `ToolSpec` that carries both its JSON Schema and its handler, so the
advertised catalog and the dispatcher cannot drift apart; adding a tool means adding
one entry to `CITools.specs`.

**A note on "failed":** `failed_only` and `asc_ci_latest_failure` treat a *run* as
failed when its `completionStatus` is `FAILED`, `ERRORED`, or `INVALID` — a run
someone canceled by hand is not a red build. The failure reports additionally collect
`CANCELED` *actions*, because Xcode Cloud cancels an action's siblings when one
breaks and those still carry the issues that explain it.

### Run it

```bash
swift build -c release
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_PRIVATE_KEY_PATH=/path/AuthKey_XXXX.p8
./.build/release/app-store-connect-mcp
```

### Register with a client

`.mcp.json` / `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "app-store-connect": {
      "command": "/absolute/path/to/app-store-connect-mcp",
      "env": {
        "ASC_KEY_ID": "…",
        "ASC_ISSUER_ID": "…",
        "ASC_PRIVATE_KEY_PATH": "/absolute/path/AuthKey_XXXX.p8"
      }
    }
  }
}
```

## Development

```bash
swift build
swift test --enable-code-coverage --no-parallel
swift-format lint -r -s --configuration .swift-format Sources Tests
```

Build the documentation locally:

```bash
swift package --allow-writing-to-directory ./docs generate-documentation \
    --target AppStoreConnectKit --disable-indexing \
    --transform-for-static-hosting --hosting-base-path app-store-connect-mcp \
    --output-path ./docs
```

### Coverage

CI runs `scripts/coverage-gate.sh` after the macOS test job and **fails the build if
line coverage drops below the floor** (`MIN_LINE_COVERAGE`, currently `85`; actual is
~88%). Run it locally the same way:

```bash
swift test --enable-code-coverage --no-parallel
MIN_LINE_COVERAGE=85 scripts/coverage-gate.sh
```

Raise the floor as coverage climbs; don't lower it without a deliberate reason.

## Releasing

Releases are tag-driven. Push a bare-SemVer tag (no `v` prefix) on `main`:

```bash
git tag 0.2.0
git push origin 0.2.0
```

`.github/workflows/release.yml` then builds the `app-store-connect-mcp` binaries
(macOS universal + Linux), stamps the version, generates notes from the commit
history, and publishes a GitHub Release with the artifacts and checksums.

## License

MIT — see [LICENSE](LICENSE).
