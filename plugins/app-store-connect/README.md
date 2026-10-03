# App Store Connect by ShipItSwifty

Investigate Xcode Cloud failures, App Review and TestFlight status, production diagnostics, and
release readiness from Claude, and optionally prepare or submit a release. This independent
MIT-licensed plugin is maintained by ShipItSwifty and is not affiliated with or endorsed by Apple.

## What it includes

| Skill | Workflow |
|---|---|
| `app-store-connect` | General playbooks: CI failures, rejections, TestFlight visibility, crashes, signing, release health. |
| `triage-ci-failure` | Find the latest failed Xcode Cloud run and explain the cause with log evidence. |
| `review-readiness` | Check whether a version is ready for review, or why a submission is stuck or rejected. |
| `prepare-release` | Draft release notes and a plan, then change metadata or submit only when you ask. |

The plugin starts a local `app-store-connect-mcp` server over stdio. Its launcher runs the
executable already installed on your `PATH`; it does not download, install, or build software.
Install the server before enabling the plugin.

## Install and configure in Claude Code

Install the server (macOS and Linux):

```sh
brew install ShipItSwifty/tap/app-store-connect-mcp
app-store-connect-mcp --version
```

For a source build, follow the repository's
[server setup guide](https://github.com/ShipItSwifty/app-store-connect-mcp/blob/main/guides/mcp-setup.md).
Make sure the executable is on the `PATH` of the process that starts Claude Code.

Install the plugin from Claude Code:

```text
/plugin marketplace add ShipItSwifty/app-store-connect-mcp
/plugin install app-store-connect@shipitswifty-app-store-connect
```

When enabling the plugin, enter the key ID and issuer ID of an App Store Connect **Team** API
key and select its `AuthKey_XXXX.p8` file. The Xcode Cloud (`ci*`) tools need Developer,
App Manager, or Admin access; finance-only keys get 403 on them. A sales-report vendor number is
optional. Write tools are off by default; enable them explicitly when you need them.
The plugin supplies its configured credentials and write setting to the server rather than
using credentials inherited from your shell.

Try: “Explain the latest failed Xcode Cloud build for `com.example.app`.”

## Claude surfaces

Claude Code loads the local server and prompts for configuration. Claude chat loads the skills
but ignores local MCP servers, so this plugin alone cannot access App Store Connect data there.
Local Cowork supports local servers, but currently skips servers whose required user
configuration has no default; this plugin requires a key. A hosted connector would be needed
for access in chat.

## Data and actions

The server reads the selected key file locally, signs a short-lived JWT, and sends authenticated
requests to `https://api.appstoreconnect.apple.com` and returns results to your Claude session.
It keeps the authenticated client and token in process memory and does not persist data.
Claude's handling of conversation content follows your Claude account's settings and policies.

Results can include app, build, tester, review, and sales data for the account the key can see.
By default every tool is read-only. Enabled write tools can start builds, change release
metadata, submit a version for review, and request analytics reports; the release skill asks
for confirmation before changing App Store Connect state. Apple limits each key to an hourly
request budget; the server reports usage as it nears the limit.

## License and support

MIT — see [LICENSE](LICENSE). Report problems in
[GitHub issues](https://github.com/ShipItSwifty/app-store-connect-mcp/issues).
