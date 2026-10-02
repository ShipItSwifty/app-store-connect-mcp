# Claude plugin setup and submission

This repository is also a local Claude Code plugin. The repository root is the
plugin folder: `.claude-plugin/plugin.json` declares its identity and configuration,
`.mcp.json` starts the server, and `skills/` supplies CI triage, review readiness,
and release preparation workflows.

## Try the plugin

Install the server as described in the [main README](../README.md), or build the
binary from this checkout. Use this checkout's binary to try the MCP 2 support
before a release containing it has been published:

```sh
swift build --product app-store-connect-mcp
swift build --show-bin-path
claude plugin validate .
claude --plugin-dir .
```

In Claude Code, configure the plugin when prompted:

| Setting | Value |
| --- | --- |
| MCP server executable | Absolute path to `app-store-connect-mcp` in the build directory or your installed copy |
| Key ID and issuer ID | A matching App Store Connect Team API key |
| Private key file | Absolute path to its `AuthKey_XXXX.p8` file |
| Vendor number | Optional; needed as the default for sales reports |
| Enable write tools | Off by default; turn on only when you want release/build write tools |

The launcher checks the explicit paths and executes the configured binary. It
does not download software, install packages, or copy the key. Credentials are
passed from the plugin's sensitive configuration to the local process; Apple
requests use signed JWTs. The raw `.p8` key is read locally. Do not commit your
credentials to this repository or put them in chat.

Use `/mcp` to check the connection, then try:

- “Explain the latest failed Xcode Cloud build for my app.”
- “Is version 1.2 of my app ready for review?”
- “Draft release notes from these changes.”

The skills appear as `/app-store-connect:triage-ci-failure`,
`/app-store-connect:review-readiness`, and `/app-store-connect:prepare-release`.
Readiness and triage use read tools. Release preparation drafts changes first and
uses write tools only for the user's requested actions.

If you already registered this server manually, disable that duplicate registration
while trying the plugin. A plugin install does not update a separately installed
server binary: install the corresponding release when updating the plugin.

## Supported Claude surfaces

This package targets Claude Code on macOS and Linux. It uses a local stdio server
and required `userConfig` settings. Claude chat ignores local servers, and Cowork
does not prompt for those required values. The skills themselves are portable,
but require access to the MCP tools to carry out their workflows. See Anthropic's
[platform support table](https://claude.com/docs/plugins/platform-support).

For chat support, a separate hosted HTTPS Streamable HTTP service is needed.
That service needs authentication, Apple-key onboarding, and an API client/cache
isolated for each account. The current executable uses one API key per process
and has no HTTP listener. Do not deploy it as a shared account service.

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

1. Publish the changes to a public GitHub repository and choose the branch or tag
   the directory should follow. Submit the repository root as the plugin folder.
2. Run `claude plugin validate .` and exercise all three workflows with a test
   App Store Connect account in Claude Code. `CLAUDE.md` at the repository root is
   development context; a validator warning that it is not loaded by the plugin
   is expected. The plugin's instructions are in its skills.
3. Open [the directory developer portal](https://claude.ai/directory/manage) from
   a paid Claude account. Choose **Plugin bundle**, enter the repository and
   source revision, then select **Validate**.
4. Resolve blocking findings and submit for review. Disclose that the launcher
   executes a separately installed, user-configured native binary and that the
   package targets Claude Code. This execution path can require human review;
   local schema validation cannot establish directory approval.
5. After approval, publish the listing from the portal. Increase the plugin
   manifest version on future plugin releases and keep the documented binary
   installation current.

Include the project documentation, MIT license, supported platforms, credential
setup, read-only defaults, and screenshots/example conversations with private
data removed. For live functional review, use a populated test account and the
minimum API key permissions needed. Do not send production credentials.

The hosted service, if built later, needs its own **MCP connector** submission;
the plugin can then reference that same endpoint. See Anthropic's
[submission guide](https://claude.com/docs/directory/publish) and
[plugin checklist](https://claude.com/docs/plugins/pre-submission-checklist).

## Maintainer checks

```sh
swift test --no-parallel
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
claude plugin validate .
python3 scripts/smoke-mcp.py "$(swift build --show-bin-path)/app-store-connect-mcp"
```

The smoke check exercises discovery and catalog access on the real stdio binary,
then starts a fresh process and checks the legacy handshake. It removes Apple
credentials from its child environment and makes no Apple API calls.
