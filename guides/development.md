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
scripts/build-docs.sh ./docs
python3 scripts/check-package-consumer.py
```

The documentation build analyzes both library catalogs, treats warnings as errors,
and merges them into one static site. Pull requests validate docs without deploying.
The consumer check builds both libraries from a temporary semantic-versioned snapshot,
including pending local changes, without changing this repository's index or tags.

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

Releases are tag-driven. Before tagging, update both
`plugins/app-store-connect/.claude-plugin/plugin.json` and `ASCMCPVersion.current`
in `Sources/AppStoreConnectMCPServer/Entry.swift` to the release version. Run tests,
the coverage gate, format lint, the plugin check (`python3 scripts/check-plugin.py`),
the documentation build, and the downstream consumer check above.

The release workflow rejects a plugin version that does not match the tag. The
binary version is also stamped from the tag during archive builds. Keep migration
notes and user-facing changes in PR descriptions for generated release notes.

Push a new bare-SemVer tag (no `v` prefix) on `main`:

```bash
git tag 0.2.2
git push origin 0.2.2
```

`.github/workflows/release.yml` then builds the `app-store-connect-mcp` binaries
(macOS universal + Linux), stamps the version, generates notes from the commit
history, and publishes a GitHub Release with the artifacts and checksums.

If the intended tag already exists, inspect its commit before releasing. Fixes
committed after a tag are not included in it. Use a new version for an already
published release rather than moving its tag.
