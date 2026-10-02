#!/bin/sh
# Runs the user's explicitly configured executable. No installs or downloads.
set -eu

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

case "${ASC_MCP_BINARY:-}" in
    /*) ;;
    *) fail 'Configure an absolute path to the app-store-connect-mcp executable in the plugin settings.' ;;
esac
[ -f "$ASC_MCP_BINARY" ] && [ -x "$ASC_MCP_BINARY" ] || fail 'The configured MCP server executable is missing or not executable.'

if [ "$#" -eq 0 ]; then
    [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || fail 'Configure the App Store Connect key ID and issuer ID in the plugin settings.'
    case "${ASC_PRIVATE_KEY_PATH:-}" in
        /*) ;;
        *) fail 'Configure an absolute path to the AuthKey .p8 file in the plugin settings.' ;;
    esac
    [ -f "$ASC_PRIVATE_KEY_PATH" ] && [ -r "$ASC_PRIVATE_KEY_PATH" ] || fail 'The configured private key file is missing or not readable.'
fi

# Use the explicit file setting even if the parent process has a different raw key.
unset ASC_PRIVATE_KEY
exec "$ASC_MCP_BINARY" "$@"
