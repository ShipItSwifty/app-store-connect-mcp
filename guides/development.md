# Development and releases

## Development

```bash
swift build
swift test --enable-code-coverage --no-parallel
MIN_LINE_COVERAGE=85 scripts/coverage-gate.sh
xcrun swift-format lint --recursive --strict --configuration .swift-format Sources Tests
```

CI runs all four on macOS plus a Linux build and test (`swift:6.3-noble`).

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

