#!/usr/bin/env python3
"""Build both libraries from a temporary semantic-versioned repository snapshot."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="asc-package-consumer-") as temporary:
    workspace = Path(temporary)
    repository = workspace / "app-store-connect-mcp"
    repository.mkdir()
    # Include pending changes when run locally, without altering the real index or tags.
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    for name in set(paths):
        source = root / name
        if not name or not source.is_file() or ".build" in Path(name).parts:
            continue
        destination = repository / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    run("git", "init", "--quiet", cwd=repository)
    run("git", "add", ".", cwd=repository)
    run(
        "git", "-c", "user.name=Package consumer check",
        "-c", "user.email=package-check@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "--quiet", "-m", "Package consumer fixture", cwd=repository,
    )
    run("git", "tag", "0.0.0", cwd=repository)

    consumer = workspace / "consumer"
    sources = consumer / "Sources" / "Consumer"
    sources.mkdir(parents=True)
    (consumer / "Package.swift").write_text(
        '// swift-tools-version: 6.3\nimport PackageDescription\n'
        'let package = Package(name: "Consumer", platforms: [.macOS(.v15)], '
        f'dependencies: [.package(url: {json.dumps(repository.as_uri())}, exact: "0.0.0")], '
        'targets: [.executableTarget(name: "Consumer", dependencies: ['
        '.product(name: "AppStoreConnectKit", package: "app-store-connect-mcp"), '
        '.product(name: "AppStoreConnectUploadKit", package: "app-store-connect-mcp")])])\n'
    )
    (sources / "main.swift").write_text(
        'import AppStoreConnectKit\n'
        '#if os(macOS)\nimport AppStoreConnectUploadKit\n#endif\n'
        'let credentials = ASCCredentials(keyID: "example", issuerID: "example", privateKeyPEM: "example")\n'
        'let client = AppStoreConnectClient(credentials: credentials, retryPolicy: .disabled)\n'
        '#if os(macOS)\nlet uploader = IPAUploadService(client: client)\n#endif\n'
    )
    run("swift", "build", cwd=consumer)
    print("Versioned downstream library build passed.")
