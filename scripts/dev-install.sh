#!/bin/bash

# Local development helper. Native Omarchy plugin installs do not run this script.
set -euo pipefail

restart=true
if [[ ${1:-} == "--no-restart" ]]; then
  restart=false
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--no-restart]" >&2
  exit 2
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
plugin_id="ericvrp.bar-autohide"
plugin_dir="$config_home/omarchy/plugins/$plugin_id"
legacy_plugin_dir="$config_home/omarchy/plugins/autohide"
shell_config="$config_home/omarchy/shell.json"
defaults="${OMARCHY_PATH:-/usr/share/omarchy}/config/omarchy/shell.json"

mkdir -p "$plugin_dir" "$(dirname -- "$shell_config")"

if [[ $repo_dir != "$plugin_dir" ]]; then
  install -m 0644 "$repo_dir/manifest.json" "$plugin_dir/manifest.json"
  install -m 0644 "$repo_dir/Service.qml" "$plugin_dir/Service.qml"
  mkdir -p "$plugin_dir/scripts"
  install -m 0644 "$repo_dir/scripts/bar-state-writer.sh" \
    "$plugin_dir/scripts/bar-state-writer.sh"
fi
rm -f "$plugin_dir/cursor_poll.py"
rm -rf "$legacy_plugin_dir"

if [[ ! -f $shell_config ]]; then
  if [[ ! -f $defaults ]]; then
    echo "Cannot find an Omarchy shell config at $shell_config or $defaults" >&2
    exit 1
  fi
  cp "$defaults" "$shell_config"
fi

python3 - "$shell_config" <<'PY'
import json
import os
import shutil
import sys
import tempfile
import time

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)

plugins = config.setdefault("plugins", [])
filtered = [
    entry for entry in plugins
    if not (isinstance(entry, dict) and entry.get("id") == "autohide")
]
enabled = any(
    isinstance(entry, dict) and entry.get("id") == "ericvrp.bar-autohide"
    for entry in filtered
)
if len(filtered) != len(plugins) or not enabled:
    backup = f"{path}.bak.{time.time_ns()}"
    shutil.copy2(path, backup)
    if not enabled:
        filtered.append({"id": "ericvrp.bar-autohide"})
    config["plugins"] = filtered

    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix="shell.json.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(config, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, os.stat(path).st_mode)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise
    print(f"Enabled ericvrp.bar-autohide; backup: {backup}")
else:
    print("ericvrp.bar-autohide is already enabled")
PY

if $restart; then
  command -v omarchy >/dev/null || { echo "omarchy is required to restart the shell" >&2; exit 1; }
  omarchy restart shell
fi

echo "Installed local development build to $plugin_dir"
