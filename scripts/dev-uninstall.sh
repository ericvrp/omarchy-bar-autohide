#!/bin/bash

# Local development helper. Native Omarchy plugin removals do not run this script.
set -euo pipefail

restart=true
if [[ ${1:-} == "--no-restart" ]]; then
  restart=false
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--no-restart]" >&2
  exit 2
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
plugin_id="ericvrp.bar-autohide"
plugin_dir="$config_home/omarchy/plugins/$plugin_id"
legacy_plugin_dir="$config_home/omarchy/plugins/autohide"
shell_config="$config_home/omarchy/shell.json"

if [[ -f $shell_config ]]; then
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

plugins = config.get("plugins", [])
filtered = [
    entry for entry in plugins
    if not (
        isinstance(entry, dict)
        and entry.get("id") in {"autohide", "ericvrp.bar-autohide"}
    )
]

if len(filtered) != len(plugins):
    backup = f"{path}.bak.{time.time_ns()}"
    shutil.copy2(path, backup)
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
    print(f"Disabled ericvrp.bar-autohide; backup: {backup}")
else:
    print("ericvrp.bar-autohide is already disabled")
PY
fi

rm -rf "$plugin_dir"
rm -rf "$legacy_plugin_dir"

# The running service restores the captured bar state on destruction. Do not
# remove bar-off here: a queued service writer owns that state transition.

if $restart; then
  command -v omarchy >/dev/null || { echo "omarchy is required to restart the shell" >&2; exit 1; }
  omarchy restart shell
fi

echo "Uninstalled local development build"
