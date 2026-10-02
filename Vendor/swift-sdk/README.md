# Vendored MCP Swift SDK

This is the `MCP` library from [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk), version 0.12.1, with the experimental capability value fix from commit `46dec85bd63c1e4909718b024d243bc92c7d403d` applied to `Sources/MCP/Client/Client.swift`.

The original fork used for that fix is no longer available. This copy also has
local server support for the `2026-07-28` revision. Keep the patches aligned with
upstream and replace the vendored copy when an upstream release covers both the
capability fix and the server behavior this project uses.

## Local protocol changes

- `ModernProtocol.swift` validates per-request version/capabilities/identity and
  defines discovery. `Server.swift` attaches that metadata to a task-local dispatch
  context, adds modern result envelopes and conservative cache fields, and keeps
  legacy initialization state separate. Removed methods cannot run on modern
  requests. Batches remain a legacy path.
- Modern dispatch adds `resultType`, server identity, and cache fields at the wire
  boundary. Existing legacy result types and response shapes remain intact. The
  generic client and typed result APIs are still legacy APIs; this is not a full
  modernization of the SDK's client, sampling, or elicitation implementation.
- `Version.latest` identifies the modern server revision. Handshake and client
  defaults use `Version.latestLegacy` so they never advertise a revision they
  cannot implement. `Version.negotiate` negotiates legacy revisions only.
- Protocol errors `-32020`, `-32021`, and `-32022` preserve structured error data.
  Parameter decoding failures become invalid-params errors.
- Stateless HTTP validates body metadata and matching protocol/method/name
  headers, handles Base64 name values, and returns HTTP 400 for modern metadata
  and header errors. Error bodies preserve the request ID and error data. The
  adapter assigns unique internal request IDs to isolate concurrent HTTP requests
  and cancels pending work when its HTTP handler is cancelled.
- Stateful HTTP remains a legacy transport and does not claim modern support.
  Client/server capability models can carry an `extensions` map; this project
  advertises no optional extensions.

The App Store Connect executable exposes tools, resources, and prompts over
stdio. No HTTP listener, subscriptions, MRTR interactions, MCP Apps, or Tasks
extension has been added. Core server-initiated interaction APIs are rejected
inside modern handlers rather than sending legacy requests to a modern client.
App Store Connect's server does not depend on those APIs.

The reusable changes should be proposed to
[modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
with their protocol contract checks. They have not been submitted upstream.
