#!/usr/bin/env bash
# Remove the Grok collector, watcher, and usage record.
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"

systemctl --user disable --now omarchy-agent-usage-grok.service >/dev/null 2>&1 || true
rm -f "$CONFIG/systemd/user/omarchy-agent-usage-grok.service"
rm -f "$CONFIG/omarchy/agents/omarchy-agent-usage-grok"
rm -f "$CONFIG/omarchy/agents/omarchy-agent-usage-grok-watch"
rm -f "$CONFIG/omarchy/hooks/post-boot.d/start-grok-usage-collector.hook"
rm -f "$STATE/omarchy/agents/usage/grok.json"
rmdir "$CONFIG/omarchy/agents" 2>/dev/null || true

systemctl --user daemon-reload >/dev/null 2>&1 || true

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell omarchy.agents refresh >/dev/null 2>&1 || true
fi

echo "Removed Grok usage collector."
