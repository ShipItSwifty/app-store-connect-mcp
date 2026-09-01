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

## Install (library)

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

## MCP server

### Credentials

Set these environment variables (same names as `altool` / Fastlane):

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY` (raw `.p8` PEM contents) **or** `ASC_PRIVATE_KEY_PATH` (path to the file)

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `asc_ci_list_products` | `app_id?` | Xcode Cloud products |
| `asc_ci_list_workflows` | `product_id` | workflows for a product |
| `asc_ci_list_build_runs` | `workflow_id`, `limit?` | recent build runs, newest first |
| `asc_ci_get_build_run` | `build_run_id` | the run + its actions with issue counts |
| `asc_ci_get_issues` | `build_action_id` | errors / warnings / analyzer findings (file + line) |
| `asc_ci_get_test_results` | `build_action_id` | test results |
| `asc_ci_get_artifacts` | `build_action_id` | log bundle / xcresult / product download URLs |
| `asc_ci_failure_report` | `build_run_id`, `workflow_name?` | **one aggregated payload**: every failed action's issues, failed tests, and artifacts |

The server does no analysis of its own — the calling agent reasons over the data.

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
swift test
swift-format lint -r -s --configuration .swift-format Sources Tests
```

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
