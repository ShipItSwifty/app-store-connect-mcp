# app-store-connect-mcp — working notes

A Swift package with three products: `AppStoreConnectKit` (the reusable client,
macOS + Linux), `AppStoreConnectUploadKit` (macOS-only IPA upload), and the
`app-store-connect-mcp` executable (an MCP server over the Xcode Cloud read API).
`AppStoreConnectKit` is consumed by ShipItSwifty, so its public API is real API.

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
- **jwt-kit is pinned to 5.4.x on purpose.** 5.5+ pulls in ML-DSA code that needs a
  newer swift-crypto than the stable CI images carry.
- **Apple `.p8` keys don't parse through swift-asn1 1.x.** `JWTGenerator` falls back
  to scanning the DER for the private scalar; don't "simplify" that away.

## Layout

- `Sources/AppStoreConnectKit/` — client, auth, rate limiting, CI read API, services.
  `Models/WireResources.swift` holds the decoding shapes shared by more than one
  service; per-service request bodies stay private to that file.
- `Sources/AppStoreConnectMCPServer/Tools/` — `ToolSpec` (schema + handler in one
  value) and `CITools.specs`, the single list the server advertises and dispatches.
  Adding a tool means adding one spec; there is no separate `switch` to update.
