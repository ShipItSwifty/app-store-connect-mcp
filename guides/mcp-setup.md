# MCP server setup

## Quick start

```bash
brew install ShipItSwifty/tap/app-store-connect-mcp
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_PRIVATE_KEY_PATH=/absolute/path/AuthKey_XXXX.p8
scripts/install-mcp.sh        # from a checkout of this repo; registers every client it finds
```

Then ask your agent things like:

- *"Why did the last Xcode Cloud build of com.example.app fail?"*
- *"Version 2.3 was rejected — what do I need to fix?"*
- *"External testers can't see build 418. Why?"*
- *"Are hangs worse in the latest release?"*
- *"Give me a release health check for com.example.app."*

## What a host gets

| MCP feature | What this server provides |
|---|---|
| **Tools** | 35 read-only [`asc_*` tools](mcp-tools.md#tools), all advertised with `readOnlyHint: true`, plus 7 write tools only when writes are enabled. |
| **Prompts** | Five [investigation playbooks](mcp-tools.md#prompts) — in Claude Code they appear as `/mcp__app-store-connect__<name>`. |
| **Resources** | The template `asc://apps/{bundle_id}/latest-failure`, which reads the latest failed Xcode Cloud report for an app as `application/json`. |
| **Instructions** | A short guide sent in the `initialize` result: where to start, which tool collapses a multi-call walk into one, and the rate-limit budget. Hosts that support it put this in the model's context before the first call. |

Tool results are compact JSON (sorted keys, no indentation) and JSON responses also carry
MCP `structuredContent` for hosts that consume typed results — the reader is a model, and
whitespace on a nested failure report is tokens you pay for. One API client is shared for
the life of the server process, so the signed JWT is reused and the rate-limit position
carries across calls.

## Install

**Homebrew** (macOS and Linux) — from the [ShipItSwifty tap](https://github.com/ShipItSwifty/homebrew-tap):

```bash
brew install ShipItSwifty/tap/app-store-connect-mcp
```

`brew upgrade app-store-connect-mcp` tracks new releases. This puts
`app-store-connect-mcp` on your `PATH`; use `which app-store-connect-mcp` for the
absolute path a client's `command` field needs.

Otherwise build from source — see [Run it](#run-it).

## Credentials

Set these environment variables (same names as `altool` / Fastlane):

| Variable | Required | Meaning |
|---|---|---|
| `ASC_KEY_ID` | yes | The API key id |
| `ASC_ISSUER_ID` | yes | Your team's issuer id |
| `ASC_PRIVATE_KEY_PATH` | one of these two | Absolute path to the `.p8` file |
| `ASC_PRIVATE_KEY` | one of these two | The raw `.p8` PEM contents |
| `ASC_VENDOR_NUMBER` | no | Default vendor number for `asc_sales_report` |
| `ASC_ENABLE_WRITES` | no | `1` / `true` / `yes` advertises the [write tools](mcp-tools.md#writes-opt-in); anything else keeps the server read-only |

Credentials are read on the first tool call, not at startup, so the server starts (and
lists its tools) without them; a call made with them missing returns an error naming the
variables.

### Key role and JWT audience

- **The API key needs a role that can read Xcode Cloud.** Use a **Team key** with
  **Developer**, **App Manager**, or **Admin** access. A key scoped only to
  Finance / Sales / Customer Support / Marketing gets `403 FORBIDDEN` on the `ci*`
  endpoints (`/v1/ciProducts`, …) even though App Store metadata calls succeed.
- **The signed JWT must carry `aud: "appstoreconnect-v1"`.** `AppStoreConnectKit`
  sets this for you (`JWTGenerator`), along with ES256 signing and a ≤20-minute
  lifetime — the values Apple requires. If you mint tokens yourself for the raw
  `get` client, a missing or wrong `aud` is the usual cause of a `401` with an
  `NOT_AUTHORIZED` / `no valid 'aud'` detail.

## Run it

```bash
swift build -c release
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_PRIVATE_KEY_PATH=/path/AuthKey_XXXX.p8
./.build/release/app-store-connect-mcp
```

## Register with a client

Run `scripts/install-mcp.sh` to detect whichever of Claude Code, Claude Desktop,
Codex CLI, Cursor, and Windsurf you have installed and register the server with
each, one confirmation prompt per client. It merges into each client's existing
config (other servers are untouched) and never runs on its own — not from
`brew install`, not from `swift build`, only when you invoke it:

```bash
scripts/install-mcp.sh
```

Registration is user-wide, available across projects (Claude Code uses `--scope user`).
The installer prefers `--binary`, otherwise it uses the executable on `PATH`, including Homebrew.

Or register by hand — the clients below point `command` at the binary
Homebrew already put on your `PATH`; run `which app-store-connect-mcp` first and
use that absolute path if a client doesn't inherit your shell's `PATH` (GUI apps
often don't).

### Claude Code

```bash
claude mcp add --scope user app-store-connect \
  --env ASC_KEY_ID=… \
  --env ASC_ISSUER_ID=… \
  --env ASC_PRIVATE_KEY_PATH=/absolute/path/AuthKey_XXXX.p8 \
  -- $(which app-store-connect-mcp)
```

This writes to `~/.claude.json` (use `--scope project` to write `.mcp.json` in the
repo instead, or `--scope local` for a project-local entry only you see).

### Claude Desktop

Add to `claude_desktop_config.json` (Settings → Developer → Edit Config):

```json
{
  "mcpServers": {
    "app-store-connect": {
      "command": "/opt/homebrew/bin/app-store-connect-mcp",
      "env": {
        "ASC_KEY_ID": "…",
        "ASC_ISSUER_ID": "…",
        "ASC_PRIVATE_KEY_PATH": "/absolute/path/AuthKey_XXXX.p8"
      }
    }
  }
}
```

### Codex CLI

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.app-store-connect]
command = "/opt/homebrew/bin/app-store-connect-mcp"

[mcp_servers.app-store-connect.env]
ASC_KEY_ID = "…"
ASC_ISSUER_ID = "…"
ASC_PRIVATE_KEY_PATH = "/absolute/path/AuthKey_XXXX.p8"
```

Or via the CLI: `codex mcp add app-store-connect -- /opt/homebrew/bin/app-store-connect-mcp`.

### Cursor

Add to `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global):

```json
{
  "mcpServers": {
    "app-store-connect": {
      "command": "/opt/homebrew/bin/app-store-connect-mcp",
      "env": {
        "ASC_KEY_ID": "…",
        "ASC_ISSUER_ID": "…",
        "ASC_PRIVATE_KEY_PATH": "/absolute/path/AuthKey_XXXX.p8"
      }
    }
  }
}
```

### Windsurf

Add to `~/.codeium/windsurf/mcp_config.json` (Windsurf Settings → MCP Servers → View
raw config):

```json
{
  "mcpServers": {
    "app-store-connect": {
      "command": "/opt/homebrew/bin/app-store-connect-mcp",
      "env": {
        "ASC_KEY_ID": "…",
        "ASC_ISSUER_ID": "…",
        "ASC_PRIVATE_KEY_PATH": "/absolute/path/AuthKey_XXXX.p8"
      }
    }
  }
}
```

> `/opt/homebrew/bin` is the default Homebrew prefix on Apple Silicon; Intel Macs and
> Linuxbrew use `/usr/local/bin` and `/home/linuxbrew/.linuxbrew/bin` respectively —
> confirm with `which app-store-connect-mcp`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Missing App Store Connect credentials` | `ASC_KEY_ID` / `ASC_ISSUER_ID` / a key variable aren't set **in the client's config** — GUI apps don't inherit your shell environment. `ASC_PRIVATE_KEY_PATH` must be absolute and readable. |
| `401` / `NOT_AUTHORIZED` | Key id and issuer id don't belong together, the key was revoked, or the `.p8` isn't the one for that key id. |
| `403 FORBIDDEN` on `asc_ci_*` only | The key's role can't read Xcode Cloud. Use a Team key with Developer, App Manager, or Admin. |
| `403` on `asc_sales_report` only | Sales reports need a key with Finance or Sales access (or Admin). |
| Server doesn't start from a GUI client | `command` isn't an absolute path. Use the output of `which app-store-connect-mcp`. |
| Write tool answers "set ASC_ENABLE_WRITES" | Working as intended — writes are opt-in. |
| Calls slow down and a ⚠️ rate-limit block appears | The key is near Apple's hourly limit; requests pause at 90%. Narrow the investigation or wait. |

Check the binary by hand: `app-store-connect-mcp --version`, or pipe an `initialize` +
`tools/list` handshake into it as CI's smoke test does (`.github/workflows/ci.yml`).

