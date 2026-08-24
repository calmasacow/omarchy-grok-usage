#!/usr/bin/env bash
# Install the Grok collector for Omarchy's stock agents panel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
AGENTS_DIR="$CONFIG/omarchy/agents"
UNIT_DIR="$CONFIG/systemd/user"
HOOK_DIR="$CONFIG/omarchy/hooks/post-boot.d"

mkdir -p "$AGENTS_DIR" "$UNIT_DIR" "$HOOK_DIR"

install -m 0755 "$ROOT/collectors/omarchy-agent-usage-grok" "$AGENTS_DIR/"
install -m 0755 "$ROOT/collectors/omarchy-agent-usage-grok-watch" "$AGENTS_DIR/"
install -m 0644 "$ROOT/systemd/omarchy-agent-usage-grok.service" "$UNIT_DIR/"
install -m 0755 "$ROOT/hooks/start-grok-usage-collector.hook" "$HOOK_DIR/"

python3 "$AGENTS_DIR/omarchy-agent-usage-grok" --force --write >/dev/null

systemctl --user daemon-reload
systemctl --user enable --now omarchy-agent-usage-grok.service

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell omarchy.agents refresh >/dev/null 2>&1 || true
fi

echo "Installed Grok usage collector."
echo "  collector: $AGENTS_DIR/omarchy-agent-usage-grok"
echo "  watcher:   systemctl --user status omarchy-agent-usage-grok.service"
echo
echo "Left-click the robot head in the bar. You should see a Grok chip."
