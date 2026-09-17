#!/usr/bin/env bash
# Uninstaller for Carla-MIDI-Daemon.
# Removes the service and binary. Keeps your config unless you pass --purge.
set -uo pipefail

BIN="$HOME/.local/bin/carla-midi-daemon"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/carla-midi-daemon.service"

echo ">> Uninstalling Carla-MIDI-Daemon"

systemctl --user disable --now carla-midi-daemon.service 2>/dev/null || true
rm -fv "$UNIT" "$BIN"
systemctl --user daemon-reload 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  rm -rfv "$CFG_DIR"
  echo "   purged config dir: $CFG_DIR"
else
  echo "   kept config: $CFG_DIR  (run with --purge to remove it)"
fi

echo ">> Done."
