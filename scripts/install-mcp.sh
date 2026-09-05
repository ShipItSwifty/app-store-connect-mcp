#!/usr/bin/env bash
#
# install-mcp.sh — register app-store-connect-mcp with whichever of Claude Code,
# Claude Desktop, Codex CLI, Cursor, and Windsurf are installed on this machine.
#
# Never run automatically (not a Homebrew postinstall hook, not part of `swift build`).
# You run this by hand, it asks before touching each client's config, and every write
# is a merge — existing servers and settings in that config are left alone.
#
# Usage:
#   scripts/install-mcp.sh
#   scripts/install-mcp.sh --yes                 # skip the per-client confirmation
#   scripts/install-mcp.sh --binary /path/to/app-store-connect-mcp
#
# Credentials: reads ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH from the
# environment if set, otherwise prompts. Nothing is sent anywhere but the config
# files below — they end up on disk in plain text, same as any other MCP client
# config, so this only writes files already local to your machine.

set -euo pipefail

ASSUME_YES=0
BINARY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --binary) BINARY="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${BINARY}" ]]; then
    BINARY="$(command -v app-store-connect-mcp || true)"
fi
if [[ -z "${BINARY}" ]]; then
    echo "error: app-store-connect-mcp not found on PATH and --binary not given." >&2
    echo "       brew install ShipItSwifty/tap/app-store-connect-mcp, or pass --binary." >&2
    exit 1
fi
BINARY="$(cd "$(dirname "${BINARY}")" && pwd)/$(basename "${BINARY}")"
echo "Using binary: ${BINARY}"

prompt_var() {
    local var_name="$1" prompt_text="$2" current="${!1:-}"
    if [[ -n "${current}" ]]; then
        printf '%s' "${current}"
        return
    fi
    read -r -p "${prompt_text}: " value
    printf '%s' "${value}"
}

ASC_KEY_ID="$(prompt_var ASC_KEY_ID "ASC_KEY_ID")"
ASC_ISSUER_ID="$(prompt_var ASC_ISSUER_ID "ASC_ISSUER_ID")"
ASC_PRIVATE_KEY_PATH="$(prompt_var ASC_PRIVATE_KEY_PATH "ASC_PRIVATE_KEY_PATH (absolute path to the .p8)")"

if [[ -z "${ASC_KEY_ID}" || -z "${ASC_ISSUER_ID}" || -z "${ASC_PRIVATE_KEY_PATH}" ]]; then
    echo "error: all three of ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH are required." >&2
    exit 1
fi

confirm() {
    local message="$1"
    [[ "${ASSUME_YES}" -eq 1 ]] && return 0
    read -r -p "${message} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# Merges the "app-store-connect" entry into a JSON file's .mcpServers, creating the
# file/object as needed. Leaves every other key untouched.
merge_json_config() {
    local config_path="$1"
    mkdir -p "$(dirname "${config_path}")"
    ASC_BINARY="${BINARY}" ASC_KEY_ID="${ASC_KEY_ID}" ASC_ISSUER_ID="${ASC_ISSUER_ID}" \
        ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH}" ASC_CONFIG_PATH="${config_path}" \
        python3 - <<'PY'
import json
import os

path = os.environ["ASC_CONFIG_PATH"]
try:
    with open(path) as handle:
        config = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

config.setdefault("mcpServers", {})
config["mcpServers"]["app-store-connect"] = {
    "command": os.environ["ASC_BINARY"],
    "env": {
        "ASC_KEY_ID": os.environ["ASC_KEY_ID"],
        "ASC_ISSUER_ID": os.environ["ASC_ISSUER_ID"],
        "ASC_PRIVATE_KEY_PATH": os.environ["ASC_PRIVATE_KEY_PATH"],
    },
}

with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
    echo "  wrote ${config_path}"
}

# --- Claude Code -------------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
    if confirm "Register with Claude Code (claude mcp add, user scope)?"; then
        claude mcp add app-store-connect \
            --env "ASC_KEY_ID=${ASC_KEY_ID}" \
            --env "ASC_ISSUER_ID=${ASC_ISSUER_ID}" \
            --env "ASC_PRIVATE_KEY_PATH=${ASC_PRIVATE_KEY_PATH}" \
            -- "${BINARY}"
        echo "  registered with Claude Code"
    fi
else
    echo "Claude Code not found (no 'claude' on PATH) — skipping."
fi

# --- Claude Desktop ------------------------------------------------------------
case "$(uname -s)" in
    Darwin) claude_desktop_config="${HOME}/Library/Application Support/Claude/claude_desktop_config.json" ;;
    Linux)  claude_desktop_config="${HOME}/.config/Claude/claude_desktop_config.json" ;;
    *)      claude_desktop_config="" ;;
esac
if [[ -n "${claude_desktop_config}" && -d "$(dirname "${claude_desktop_config}")" ]]; then
    if confirm "Register with Claude Desktop (${claude_desktop_config})?"; then
        merge_json_config "${claude_desktop_config}"
        echo "  restart Claude Desktop for this to take effect"
    fi
else
    echo "Claude Desktop not found — skipping."
fi

# --- Codex CLI -----------------------------------------------------------------
if command -v codex >/dev/null 2>&1; then
    if confirm "Register with Codex CLI (codex mcp add)?"; then
        codex mcp add app-store-connect \
            --env "ASC_KEY_ID=${ASC_KEY_ID}" \
            --env "ASC_ISSUER_ID=${ASC_ISSUER_ID}" \
            --env "ASC_PRIVATE_KEY_PATH=${ASC_PRIVATE_KEY_PATH}" \
            -- "${BINARY}"
        echo "  registered with Codex CLI"
    fi
else
    echo "Codex CLI not found (no 'codex' on PATH) — skipping."
fi

# --- Cursor ----------------------------------------------------------------
cursor_config="${HOME}/.cursor/mcp.json"
if [[ -d "${HOME}/.cursor" ]] || command -v cursor >/dev/null 2>&1; then
    if confirm "Register with Cursor (${cursor_config})?"; then
        merge_json_config "${cursor_config}"
        echo "  restart Cursor for this to take effect"
    fi
else
    echo "Cursor not found — skipping."
fi

# --- Windsurf --------------------------------------------------------------
windsurf_config="${HOME}/.codeium/windsurf/mcp_config.json"
if [[ -d "${HOME}/.codeium/windsurf" ]]; then
    if confirm "Register with Windsurf (${windsurf_config})?"; then
        merge_json_config "${windsurf_config}"
        echo "  restart Windsurf for this to take effect"
    fi
else
    echo "Windsurf not found — skipping."
fi

echo
echo "Done. Re-run this script any time to re-point a client at a new binary path."
