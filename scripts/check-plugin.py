#!/usr/bin/env python3
"""Static consistency checks for the Claude plugin; needs no `claude` CLI or network."""

import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PLUGIN = os.path.join(ROOT, "plugins", "app-store-connect")
errors = []


def load(path):
    with open(os.path.join(ROOT, path)) as handle:
        return json.load(handle)


marketplace = load(".claude-plugin/marketplace.json")
manifest = load("plugins/app-store-connect/.claude-plugin/plugin.json")
mcp = load("plugins/app-store-connect/.mcp.json")

for entry in marketplace["plugins"]:
    source = os.path.normpath(os.path.join(ROOT, entry["source"]))
    if source != os.path.normpath(PLUGIN):
        errors.append(f"marketplace plugin {entry['name']} points at {entry['source']}")
    if entry["name"] != manifest["name"]:
        errors.append(f"marketplace name {entry['name']} != plugin name {manifest['name']}")

# Every ${user_config.X} must be declared; an undeclared key silently reaches the server empty.
declared = set(manifest.get("userConfig", {}))
used = set(re.findall(r"\$\{user_config\.([A-Za-z0-9_]+)\}", json.dumps(mcp)))
for key in sorted(used - declared):
    errors.append(f".mcp.json uses undeclared user_config.{key}")
for key in sorted(declared - used):
    errors.append(f"plugin.json declares user_config.{key} that .mcp.json never uses")

for server in mcp["mcpServers"].values():
    launcher = server["command"].replace("${CLAUDE_PLUGIN_ROOT}", PLUGIN)
    if not (os.path.isfile(launcher) and os.access(launcher, os.X_OK)):
        errors.append(f"launcher is missing or not executable: {launcher}")

if not os.path.isfile(os.path.join(PLUGIN, ".claude-plugin", "icon.png")):
    errors.append("missing .claude-plugin/icon.png")

skills = os.path.join(PLUGIN, "skills")
for name in sorted(os.listdir(skills)):
    path = os.path.join(skills, name, "SKILL.md")
    if not os.path.isfile(path):
        errors.append(f"skills/{name} has no SKILL.md")
        continue
    with open(path) as handle:
        match = re.match(r"---\n(.*?)\n---\n", handle.read(), re.S)
    front = dict(line.split(": ", 1) for line in (match.group(1).splitlines() if match else []) if ": " in line)
    if front.get("name") != name:
        errors.append(f"skills/{name}: frontmatter name is {front.get('name')!r}")
    if not front.get("description"):
        errors.append(f"skills/{name}: missing description")

if errors:
    print("\n".join(f"error: {message}" for message in errors), file=sys.stderr)
    sys.exit(1)
print("plugin checks passed")
