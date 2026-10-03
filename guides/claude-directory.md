# Claude directory and MCP 2.0

This repository is a Claude Code plugin marketplace with one plugin. `.claude-plugin/marketplace.json`
lists `plugins/app-store-connect`, which holds the plugin manifest and icon
(`.claude-plugin/`), `.mcp.json`, the launcher, the README and LICENSE, and the skills. The
repository root is **not** the plugin folder, so development files (`CLAUDE.md`, the vendored
SDK, CI) are outside what the directory scans.

## Try the plugin

Install the server (`brew install ShipItSwifty/tap/app-store-connect-mcp`), or put a binary built
from this checkout on your `PATH`:

```sh
swift build --product app-store-connect-mcp
export PATH="$(swift build --show-bin-path):$PATH"
claude plugin validate ./plugins/app-store-connect --strict
claude --plugin-dir ./plugins/app-store-connect
```

In Claude Code, configure the plugin when prompted: key ID and issuer ID of a Team API key,
the absolute `AuthKey_XXXX.p8` file, an optional vendor number for sales reports, and the write
switch (off by default). The launcher executes `app-store-connect-mcp` from your `PATH`; it does
not download or install software or copy the key. Use `/mcp` to check the connection, then try:

- “Explain the latest failed Xcode Cloud build for my app.”
- “Is version 1.2 of my app ready for review?”
- “Draft release notes from these changes.”

The skills appear as `/app-store-connect:triage-ci-failure`,
`/app-store-connect:review-readiness`, and `/app-store-connect:prepare-release`.
If you registered this server manually, disable that duplicate while trying the plugin. A plugin
install does not update the separately installed binary: `brew upgrade` it to match.

## Supported Claude surfaces

This package targets Claude Code. It uses a local stdio server and required `userConfig`
settings. Claude chat ignores local servers, and Cowork does not prompt for those required
values. The skills are portable but need the MCP tools to carry out their workflows. See
Anthropic's [platform support table](https://claude.com/docs/plugins/platform-support).

For chat support, a separate hosted HTTPS Streamable HTTP service is needed, with authentication,
Apple-key onboarding, and an API client/cache isolated for each account. The current executable
uses one API key per process and has no HTTP listener; do not deploy it as a shared account service.

## Protocol support

The server accepts self-contained `2026-07-28` requests with no handshake. Every
modern request must include `params._meta` with:

```json
{
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities": {}
}
```

`server/discover` reports supported versions, capabilities, instructions, and
identity metadata. Ordinary modern results have `resultType: "complete"`;
cacheable results use `ttlMs: 0` and `cacheScope: "private"` as conservative
defaults. Older clients continue to use `initialize` and their existing response
shapes. Strict legacy clients must wait for initialization to complete.

The vendored SDK's stateless HTTP adapter validates modern metadata and mirrored
`MCP-Protocol-Version`, `Mcp-Method`, and applicable `Mcp-Name` headers, including
Base64 sentinel values. It assigns internal routing IDs to keep independent
clients' requests and HTTP context separate. Stateful HTTP and the SDK client
remain legacy APIs. This server does not advertise subscriptions, elicitation,
MCP Apps, Tasks, or other extensions. See [the vendor notes](../Vendor/swift-sdk/README.md)
for the scope of the SDK changes.

## Submit the plugin bundle

1. Set `version` in `plugins/app-store-connect/.claude-plugin/plugin.json` to the release tag
   before tagging; the release workflow fails if they differ, because the field pins installed
   plugins. Push to the branch or tag the directory should follow.
2. Run `claude plugin validate ./plugins/app-store-connect --strict` and exercise all the skills
   with a test App Store Connect account, using the Homebrew-installed binary. Local validation
   checks schema, not directory policy or successful authentication.
3. Open [the developer portal](https://claude.ai/directory/manage) from a paid Claude account with
   a connected GitHub account.
4. Select **Plugin bundle**; enter `ShipItSwifty/app-store-connect-mcp`, path
   `plugins/app-store-connect`, and the branch or tag. Run **Validate** and resolve blocking
   findings.
5. Disclose that the launcher executes a separately installed native binary from `PATH`, that the
   plugin targets Claude Code, that the key file is read locally and used only to sign tokens
   for Apple's API, and that writes are off by default. External executable resolution can
   receive a reviewer hold; local validation does not establish approval.
6. Follow review feedback and publish the approved version. For functional review, provide a
   populated test account and a key with the minimum permissions; never send production
   credentials.

See Anthropic's [submission guide](https://claude.com/docs/plugins/submit) and
[plugin checklist](https://claude.com/docs/plugins/pre-submission-checklist). The hosted service,
if built later, needs its own **MCP connector** submission that the plugin can then reference.

## Maintainer checks

```sh
swift test --no-parallel
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
claude plugin validate ./plugins/app-store-connect --strict
python3 scripts/smoke-mcp.py "$(swift build --show-bin-path)/app-store-connect-mcp"
```

The smoke check exercises discovery and catalog access on the real stdio binary, then starts a
fresh process and checks the legacy handshake. It removes Apple credentials from its child
environment and makes no Apple API calls.
