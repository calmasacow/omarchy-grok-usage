# Omarchy Grok usage

Add **Grok** to Omarchy’s stock agents widget — the robot head next to Bluetooth and Wi-Fi.

Omarchy’s packaged panel already covers Claude, Codex, and Fireworks. It only *displays* JSON dropped in `~/.local/state/omarchy/agents/usage/`. This repo ships the missing Grok collector so that panel grows a Grok tab. No plugin clone, no edits under `/usr/share/omarchy`.

## What you get

- SuperGrok **weekly** pool (same source Grok Build uses for `/usage`)
- Plan name (SuperGrok, SuperGrok Pro, SuperGrok Heavy, …)
- Local prompt, session, and token stats from `~/.grok/sessions`
- Tokens by day (last week) and by model
- Prepaid leftover credits, when the ledger is actually non-zero

Right-click on the robot still launches your default coding agent. Left-click opens the usage panel; if more than one agent has data, switch with the chips or a middle-click.

## Install

On an Omarchy machine, with Grok Build already signed in (`grok login`):

```bash
git clone https://github.com/calmasacow/omarchy-grok-usage.git
cd omarchy-grok-usage
./install.sh
```

Then left-click the robot head. You should see a **Grok** chip next to Claude/Codex/Fireworks.

`install.sh` copies the collector and watcher into `~/.config/omarchy/`, enables a user systemd service, writes `grok.json`, and asks the panel to rescan.

## Uninstall

```bash
./uninstall.sh
```

## How it works

Packaged `omarchy-agent-usage-update` only scans `$OMARCHY_PATH/bin/`, so Grok cannot live there without waiting on an upstream collector. This watcher writes `~/.local/state/omarchy/agents/usage/grok.json` whenever the panel regenerates its other records, and at least every 15 minutes.

| File | Role |
|---|---|
| `collectors/omarchy-agent-usage-grok` | Session scan + SuperGrok billing probe |
| `collectors/omarchy-agent-usage-grok-watch` | Refresh on sibling usage writes, or every 15 minutes |
| `systemd/omarchy-agent-usage-grok.service` | Keep the watcher running |

No tokens are stored in this repo. The collector reads the login already in `~/.grok/auth.json`.

## Requirements

- [Omarchy](https://omarchy.org/)
- Grok Build signed in (`grok login`)
- `python3` and `inotifywait` (`inotify-tools`)

## License

MIT.
