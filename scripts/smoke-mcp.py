#!/usr/bin/env python3
"""Exercise both MCP eras over a real subprocess without Apple credentials."""

import json
import os
import selectors
import subprocess
import sys


def smoke(binary, legacy):
    environment = dict(os.environ)
    environment["ASC_ENABLE_WRITES"] = "false"
    for key in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH"):
        environment.pop(key, None)
    process = subprocess.Popen(
        [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=environment,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    request_id = 0

    def call(method, params=None):
        nonlocal request_id
        request_id += 1
        params = dict(params or {})
        if not legacy:
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {},
            }
        message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()
        if not selector.select(timeout=10):
            raise AssertionError(f"Timed out waiting for {method}")
        response = json.loads(process.stdout.readline())
        assert response["id"] == request_id, response
        assert "error" not in response, response
        result = response["result"]
        if not legacy:
            assert result["resultType"] == "complete", result
            assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "app-store-connect-mcp"
        return result

    try:
        if legacy:
            initialized = call("initialize", {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "ci-smoke", "version": "1"},
            })
            assert initialized["protocolVersion"] == "2025-11-25"
            assert initialized["instructions"]
            process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            process.stdin.flush()
        else:
            discovered = call("server/discover")
            assert "2026-07-28" in discovered["supportedVersions"]
            assert discovered["instructions"]
        tools = call("tools/list")
        assert any(tool["name"] == "asc_ci_latest_failure" for tool in tools["tools"])
        assert all(tool["title"] and tool["annotations"]["readOnlyHint"] for tool in tools["tools"])
        prompts = call("prompts/list")
        assert any(prompt["name"] == "triage_ci_failure" for prompt in prompts["prompts"])
        call("resources/list")
        call("resources/templates/list")
        call("prompts/get", {"name": "triage_ci_failure"})
        if not legacy:
            assert tools["ttlMs"] == 0 and tools["cacheScope"] == "private"
        process.stdin.close()
        assert process.wait(timeout=10) == 0
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: smoke-mcp.py /absolute/path/app-store-connect-mcp")
    smoke(sys.argv[1], legacy=False)
    smoke(sys.argv[1], legacy=True)
    print("MCP 2026-07-28 and legacy stdio smoke checks passed")
