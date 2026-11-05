# Hue Lights for Tern

Control Philips Hue lights from a native Tern pane, the command palette and the status bar, through the Hue bridge's local API.

- **Hue Lights pane:** rooms and zones with their lit and offline counts, average brightness, and **Off**/**On**, **−** and **+** controls. **All on** and **All off** cover the whole bridge. Select a room or zone to open its card with its scenes and each of its lights.
- **Status segment:** `Hue 3/3 on · 2 offline` counts lit lights out of reachable ones, then unreachable lights. Click it to open the pane.
- **Palette:** **Open Hue lights**, **Hue: all lights on**, **Hue: all lights off** and **Hue: toggle all lights**. Toggle reads the bridge first, so it turns everything off when any reachable light is lit and on otherwise.

Lights switched off at the wall, or out of Zigbee range, keep reporting their last state to the bridge. The plugin counts them as offline, never as lit.

Keys in the pane:

| Key | Action |
| --- | --- |
| `r` | Refresh now |
| Click a row | Open that room's or zone's card |
| Double-click the selected row | Close its card |

## Install

Requires Tern's native plugin API. Verified on macOS with Tern 0.9.11 and a Hue Bridge (square, model BSB002).

```sh
tern plugin install github.com/wolfiesch/tern-hue
tern plugin list
```

Or clone the repository and link it in place:

```sh
git clone https://github.com/wolfiesch/tern-hue.git
cd tern-hue
tern plugin link .
tern plugin list
```

`tern plugin list` should show `hue … ready`. To update an installed copy, run `tern plugin install github.com/wolfiesch/tern-hue --force`; for a linked clone, `git pull` then `tern plugin reload hue`. A linked directory must stay in place.

## Connect

The plugin reads the [openhue CLI](https://www.openhue.io/cli) config at `~/.openhue/config.yaml`:

```yaml
bridge: 192.168.1.2
key: <application key>
```

To create it, run `openhue setup` and press the bridge's link button when asked. To use another file in the same format, set `TERN_HUE_CONFIG` in Tern's launch environment. Keep the file readable only by you (`chmod 600`): the key controls every light on the bridge.

DHCP can move the bridge. When it stops answering at the configured address, the plugin asks Philips' discovery service (`discovery.meethue.com`) for its current LAN address, at most once every 15 minutes, and uses the new address until the config changes. A type 1 `unauthorized user` error means the key is no longer paired; run `openhue setup` again.

The pane runs on the current Tern host, so a remote host needs its own installation and config.

## Data and refresh

Requests use the bridge's v1 HTTP API (`/api/<key>/groups`, `/lights`, `/scenes`) from Tern's host half. The plugin polls every 5 seconds while a Hue pane is open and every 30 seconds otherwise, for the status segment, and re-reads scenes every 5 minutes. After a control, it reads the new state back once the bridge's transition has run.

Errors never include the application key. A bridge that stops answering keeps the last state on screen, marked stale.

The plugin changes lights only when you press a control or run a palette command. Turning lights off and on keeps their brightness and color; a scene replaces them.

## Development

- `bridge.luau`: config parsing and the v1 HTTP client, with key redaction and rediscovery.
- `model.luau`: normalization of bridge state and the request for each control.
- `view.luau`: the pane's native view.
- `host.luau`: one poller per host, the Hue Lights block and the status record windows read.
- `window.luau`: palette commands and the status segment.

From this directory, with the Luau CLI installed:

```sh
luau tests/model.test.luau
luau-analyze model.luau bridge.luau view.luau
```

CI runs the same two commands on every pull request and push to `main`. `tern plugin types .` writes `tern.d.luau` for luau-lsp.

Unit checks do not verify native rendering or the bridge. For view or control changes, also load the plugin in Tern and check the pane against a direct read of `/lights`.

Tern reloads a linked plugin each time a file is saved. A save that leaves a syntax error stops any open Hue pane; run **Open Hue lights** again after fixing it to replace the stopped pane.
