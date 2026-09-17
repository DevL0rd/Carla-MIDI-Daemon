#!/usr/bin/env bash
# Idempotent installer for Carla-MIDI-Daemon.
# Safe to re-run: it refreshes the binary/service and never clobbers your config.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin/carla-midi-daemon"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon"
CFG="$CFG_DIR/config.json"
PROJ="$CFG_DIR/BitsonicSampler.carxp"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/carla-midi-daemon.service"

echo ">> Installing Carla-MIDI-Daemon"

for c in pw-link pw-mon jq; do
  command -v "$c" >/dev/null || { echo "!! required command not found: $c (pw-link/pw-mon = pipewire, jq = jq)"; exit 1; }
done

install -Dm755 "$SRC/carla-midi-daemon.sh" "$BIN"
echo "   daemon   -> $BIN"

if [ -e "$CFG" ]; then
  echo "   config   -> $CFG (kept existing)"
else
  install -Dm644 "$SRC/config.example.json" "$CFG"
  echo "   config   -> $CFG (new — created from example)"
fi

# Carla project that auto_launch opens (kept if you've saved over it)
if [ -e "$PROJ" ]; then
  echo "   project  -> $PROJ (kept existing)"
else
  install -Dm644 "$SRC/BitsonicSampler.carxp" "$PROJ"
  echo "   project  -> $PROJ (new)"
fi

install -Dm644 "$SRC/carla-midi-daemon.service" "$UNIT"
echo "   service  -> $UNIT"

systemctl --user daemon-reload
systemctl --user enable carla-midi-daemon.service >/dev/null
systemctl --user restart carla-midi-daemon.service   # (re)start, picking up changes

echo ">> Done."
echo "   Edit devices:  $CFG"
echo "   Apply edits:   systemctl --user restart carla-midi-daemon"
echo "   Live logs:     journalctl --user -u carla-midi-daemon -f"
