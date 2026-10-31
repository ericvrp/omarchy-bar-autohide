# Developing Omarchy Bar Autohide

## Requirements

- Omarchy with the Quickshell bar
- Hyprland
- Python 3 for the local development helpers
- Bun for the service regression tests

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
bun test scripts
omarchy plugin validate .
```

The Bun tests run the real service in an isolated, offscreen Quickshell host
with temporary state and a simulated bar. They do not change the desktop.
They cover unchanged visibility probes, disable/manual-toggle/re-enable,
baseline restoration, and removal of hover observers on unload.
They also check that the opaque transition background expires after hiding
and stays disabled for glassy and transparent bar modes.

`BarTransitionBackground.qml` keeps a click-through strip below application
windows and above the wallpaper. In opaque mode it uses the bar's theme color
while the bar is visible and for 300ms after hiding (50ms with animations off).
Expanding windows cover it naturally. The surface stays mapped with transparent
pixels afterwards, avoiding compositor layer fade-in/fade-out animations.
This is a bounded workaround for the host releasing its reserved screen space
at the same time it parks the bar; unusually slow custom window animations may
outlast the cover.
Only screens whose active workspace contains a visible tiled window use the
strip; empty and floating-only workspaces show the wallpaper immediately.
The window is permanently alpha-capable and transparent, with its color drawn
in a child rectangle, so clearing the cover cannot leave an opaque black strip.

Visibility writes are serialized with `flock`. Each operation is marked as
preparing before its flag write, then waiting once the flag is ready. The
service checks pending operations until the host observes their state, even
when no visibility-change signal is emitted. Failed operations are replayed
before newer requests; an unloaded owner cannot block its own restoration.

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
