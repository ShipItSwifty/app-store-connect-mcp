#!/usr/bin/env bash
# Build and validate both libraries, then merge their static DocC sites.
set -euo pipefail

output="${1:-./docs}"
archives="$(mktemp -d)"
trap 'rm -rf "$archives"' EXIT

for target in AppStoreConnectKit AppStoreConnectUploadKit; do
    swift package --allow-writing-to-directory "$archives" generate-documentation \
        --target "$target" --analyze --warnings-as-errors --disable-indexing \
        --transform-for-static-hosting --hosting-base-path app-store-connect-mcp \
        --output-path "$archives/$target.doccarchive"
done

xcrun docc merge "$archives/AppStoreConnectKit.doccarchive" \
    "$archives/AppStoreConnectUploadKit.doccarchive" \
    --synthesized-landing-page-name "App Store Connect Libraries" \
    --output-path "$archives/Libraries.doccarchive"

# Replace only a generated DocC site, after both catalogs and the merge succeed.
python3 - "$archives/Libraries.doccarchive" "$output" <<'PY'
import json
from pathlib import Path
import shutil
import sys

source, destination = map(Path, sys.argv[1:])
if destination.exists():
    if any(destination.iterdir()):
        metadata = destination / "metadata.json"
        if not metadata.is_file() or json.loads(metadata.read_text()).get("bundleID") != "AppStoreConnectKit":
            sys.exit(f"Refusing to replace a directory that is not the generated library site: {destination}")
    shutil.rmtree(destination)
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, destination)
PY

cat > "$output/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=documentation">
    <link rel="canonical" href="documentation">
    <title>App Store Connect Libraries</title>
  </head>
  <body><p>Read the <a href="documentation">library documentation</a>.</p></body>
</html>
HTML
