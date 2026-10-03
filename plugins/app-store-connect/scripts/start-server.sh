#!/bin/sh
# Install app-store-connect-mcp before enabling the plugin; see README.md.
# Replace the launcher so stdio and termination belong to the MCP server.
exec app-store-connect-mcp "$@"
