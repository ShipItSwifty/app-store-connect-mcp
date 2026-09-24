# app-store-connect-mcp — working notes

A Swift package with three products: `AppStoreConnectKit` (the reusable client,
macOS + Linux), `AppStoreConnectUploadKit` (macOS-only IPA upload), and the
`app-store-connect-mcp` executable (an MCP server over the Xcode Cloud read API).
`AppStoreConnectKit` is consumed by ShipItSwifty, so its public API is real API.

## Toolchain

`swift-tools-version: 6.3`, language mode 6, macOS 15+. Both CI legs (the `macos-26`
runner and the `swift:6.3-noble` container) are on 6.3.3, so the manifest's floor and
CI's toolchain are the same version — bumping tools-version past what the Linux
container image provides breaks the build at manifest-parse time, before any
diagnostic you'd recognise.

## Conventions

- **Tags and versions are bare SemVer — never a `v` prefix.** `0.2.0`, not `v0.2.0`.
  This applies to git tags, GitHub releases, and SwiftPM `from:` pins.
- **Commit straight to `main`**; no feature branches for routine work.
- **No `CHANGELOG.md`.** Release notes are generated per tag by `release.yml`.
- Releases are tag-driven: pushing a `N.N.N` tag builds the macOS universal + Linux
  binaries, stamps the version into `Entry.swift`, and publishes a GitHub Release.
  `ASCMCPVersion.current` in the source is a placeholder that the workflow rewrites.

## Checks before pushing

```bash
swift build
swift test --enable-code-coverage --no-parallel
MIN_LINE_COVERAGE=85 scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
```

CI runs all four plus a Linux build. The coverage floor is a ratchet: raise it as
coverage climbs, don't lower it without a reason.

## Things that will bite you

- **App Store Connect is camelCase on the wire, in both directions.** The client
  deliberately uses a plain `JSONDecoder`/`JSONEncoder` with *no* key strategy. A
  `.convertToSnakeCase` encoder silently broke every write for several releases —
  Apple answers a malformed body by ignoring the attribute, not by erroring.
  `RequestEncodingTests` asserts outgoing bodies; keep it that way when adding writes.
- **`GET /v1/reviewSubmissions` rejects `sort`** with a 400 (`PARAMETER_ERROR.ILLEGAL`).
  Fetch a page and order client-side. `/v1/builds` *does* support `sort`.
- **List endpoints are paged.** Use `getAll(_:query:limit:)`, not `get`, for anything
  that returns a collection, or you silently truncate at one page.
- **The `ci*` endpoints need a Team key** with Developer / App Manager / Admin access;
  finance/sales-only keys get 403 on them while metadata calls still succeed.
- **jwt-kit is `.upToNextMajor(from: "5.7.1")`; swift-crypto is `from: "4.5.2"`
  (so `< 5.0.0`).** swift-crypto 5 is blocked on apple/swift-certificates, which jwt-kit
  pulls in and which still caps crypto below 5.0.0 — see the comment in `Package.swift`
  before trying to lift it.
- **The MCP SDK is a pinned fork revision** (`maniramezan/swift-sdk`), for a decoding
  fix to object-valued experimental capabilities that Codex sends
  (`ExperimentalCapabilitiesTests`). Return to upstream once a release carries it.
- **`betaGroups.publicLink` is a URL string, not a Bool.** It was modelled as `Bool`
  and threw `typeMismatch` for every group with a public link enabled. Apple's
  attribute types are worth checking against the docs JSON
  (`developer.apple.com/tutorials/data/documentation/appstoreconnectapi/<resource>/attributes-data.dictionary.json`)
  rather than guessed from the name.
- **`/v1/apps/{id}/builds` rejects `sort`; `/v1/builds?filter[app]=` accepts it.** The
  nested collection has no defined order, so `builds(appID:)` goes through the flat one.
- **Retries are on by default** (`TransientRetryPolicy`: 429 + 5xx, `Retry-After`
  honoured, `GET`-only for 5xx). Test helpers pass `.disabled` — a retry would eat the
  next queued mock response and add real backoff sleeps to the suite.
- **`diagnosticSignatures/{id}/logs` and `perfPowerMetrics` are not JSON:API.** They
  answer with `{"version":…,"productData":[…]}`, not `{"data":…}`, and both are far
  too large to hand an agent verbatim — each has a normalized summary beside it.
- **Gzip needs its trailer checked.** A corrupt member inflates to a *partial* buffer
  rather than failing, so `Gzip` verifies CRC32 and length; without that a truncated
  sales report would read as a short one.
- **Apple `.p8` keys don't parse through swift-asn1 1.x.** `JWTGenerator` falls back
  to scanning the DER for the private scalar; don't "simplify" that away.

## Layout

- `Sources/AppStoreConnectKit/` — client, auth, rate limiting, CI read API, services.
  `Models/WireResources.swift` holds the decoding shapes shared by more than one
  service; per-service request bodies stay private to that file.
- `Sources/AppStoreConnectMCPServer/Tools/` — `ToolSpec` (schema + handler in one
  value) and `CITools.specs`, the single list the server advertises and dispatches.
  `CITools.specs(writesEnabled:)` concatenates `ciSpecs`, `AppStoreTools`,
  `DiagnosticsTools`, `ReviewTools`, `ReportingTools` and — only when
  `ASC_ENABLE_WRITES` is set — `WriteTools`. Several files, still one catalog and no
  separate `switch` to update. Adding a tool means adding one spec.
- `Sources/AppStoreConnectMCPServer/Prompts/ServerPrompts.swift` — `ServerInstructions`
  (the `initialize` instructions) and `ServerPrompts` (MCP prompts, one `PromptSpec`
  each). `ServerPromptsTests` fails if either names a tool the catalog doesn't
  advertise, or a prompt names a write tool — rename a tool and they must follow.
- `skills/app-store-connect/SKILL.md` — the Claude Code skill; same playbooks as the
  prompts, in more depth. Keep the two in step when a workflow changes.
- **Tool output is compact JSON** (`CITools.json`: sorted keys, no pretty-printing), and
  `asc_api_get` passes Apple's body through verbatim. Tests assert on `"key":value`
  with no spaces.
- **One `AppStoreConnectClient` per server process** (`CITools.defaultClient`), so the
  JWT and `RateLimiter` state persist across tool calls. Tests inject their own client
  through `CITools.dispatch(…makeClient:)` and never touch the shared one.
- **Writes are opt-in and must stay that way.** A default deployment advertises a
  catalog whose every tool is `readOnlyHint: true`, which is what lets a host
  auto-approve a whole investigation. Anything that mutates belongs in `WriteTools`
  with `isReadOnly: false`; dispatch answers a disabled write tool by naming the
  environment variable rather than "unknown tool".
