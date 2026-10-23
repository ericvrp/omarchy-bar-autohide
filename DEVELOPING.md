# Developing Omarchy Bar Autohide

## Requirements

- Omarchy with the Quickshell bar
- Hyprland
- Python 3 for the local development helpers

## Local Testing

The scripts under `scripts/` are local development helpers. Omarchy does not
run them during normal plugin installation, updates, or removal.

Install the current working tree:

```bash
./scripts/dev-install.sh
```

The development installer:

- Copies the plugin to `~/.config/omarchy/plugins/ericvrp.bar-autohide`.
- Adds `{ "id": "ericvrp.bar-autohide" }` to the existing `plugins` array in
  `~/.config/omarchy/shell.json` without replacing other settings.
- Removes the legacy `autohide` development installation and configuration.
- Creates a timestamped backup before changing an existing shell config.
- Restarts the Omarchy shell.

Running the installer again updates the installed development build without
adding a duplicate configuration entry.

Remove the local development installation with:

```bash
./scripts/dev-uninstall.sh
```

The uninstaller removes both current and legacy development installations,
updates the shell configuration, and restarts the shell.

Pass `--no-restart` to either helper when testing configuration changes without
restarting the live shell.

Run the state-writer ordering checks with:

```bash
bash scripts/test-bar-state-writer.sh
```

## Configuration

`revealThickness` remains an internal `Service.qml` setting. The hide delay is
configured on the plugin entry in `~/.config/omarchy/shell.json`:

```json
{
  "plugins": [
    { "id": "ericvrp.bar-autohide", "hideDelayMs": 500 }
  ]
}
```

The default is 200ms. Values are clamped to 0–5000ms; invalid types use the
default. Restart the shell to apply a change. Re-running
`./scripts/dev-install.sh` also restarts the shell unless `--no-restart` is
passed.

The active edge is detected from `shell.bar.position`. Increasing
`revealThickness` makes the invisible edge trigger easier to reach, but also
makes that many pixels intercept pointer input while the bar is hidden or was
revealed by the edge trigger.
