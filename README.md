# app-store-connect-mcp

A reusable Swift client for the **App Store Connect API** — including the **Xcode Cloud**
(`ci*`) resource family — plus an **MCP server** that lets an AI agent investigate *what
broke*: a red Xcode Cloud build, a rejected or stuck submission, a TestFlight build testers
can't see, a hang regression in production.

Three products:

| Product | Platforms | Use it for |
|---|---|---|
| `AppStoreConnectKit` (library) | macOS, Linux | JWT auth, rate limiting, the generic REST client, App Store + TestFlight DTOs, and the typed Xcode Cloud read API (`ciProducts` → `ciWorkflows` → `ciBuildRuns` → `ciBuildActions` → `ciIssues` / `ciTestResults` / `ciArtifacts`). |
| `AppStoreConnectUploadKit` (library) | macOS only | `IPAUploadService` — orchestrates `xcrun altool --upload-app` and resolves the resulting build id. |
| `app-store-connect-mcp` (executable) | macOS, Linux | An MCP (Model Context Protocol) server exposing the App Store Connect read API as tools, plus investigation prompts. |

> `AppStoreConnectKit` is consumed by [ShipItSwifty](https://github.com/maniramezan/ShipItSwifty)
> as its App Store Connect layer.

📖 **[API documentation](https://shipitswifty.github.io/app-store-connect-mcp/)** (DocC, published from `main`).

## Get started

- **Swift libraries:** [install and use the client](guides/library.md).
- **MCP server:** [install, configure, and register it](guides/mcp-setup.md).
- **Tool catalog and prompts:** [browse the MCP reference](guides/mcp-tools.md).
- **Contributing and releases:** [development guide](guides/development.md).

The MCP server works with a Team API key and exposes read tools by default.
To try it from a checkout:

```bash
brew install ShipItSwifty/tap/app-store-connect-mcp
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_PRIVATE_KEY_PATH=/absolute/path/AuthKey_XXXX.p8
scripts/install-mcp.sh
```

For example, ask your agent: “Why did the last Xcode Cloud build of
com.example.app fail?” See the [MCP setup guide](guides/mcp-setup.md) for
credentials and supported clients.

## License

MIT — see [LICENSE](LICENSE).
