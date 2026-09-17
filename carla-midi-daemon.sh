#!/usr/bin/env bash
# Linux-Carla-MIDI-Daemon
# Auto-wires MIDI controllers and audio for Carla plugins ("samplers") on
# Linux/PipeWire, with per-plugin MIDI priority/failover.
#
# Audio always follows the system defaults — no per-device config:
#   * each sampler's outputs are routed to the current DEFAULT SINK (your
#     speakers/headphones), and
#   * mixed into whatever is capturing the current DEFAULT SOURCE (your mic),
#     so callers/recorders hear mic + Carla WITHOUT a virtual device. The
#     default mic/output are never changed and nothing appears/disappears.
# Switch your default input or output and the daemon re-routes live.
#
# Event-driven: reacts to PipeWire graph changes (pw-mon) and default in/out
# changes (pactl subscribe). No polling. Requires: pw-link, pw-mon, jq, pactl.

set -uo pipefail

CONFIG="${CARLA_MIDI_DAEMON_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon/config.json}"

log() { printf '%s carla-midi-daemon: %s\n' "$(date '+%H:%M:%S')" "$*"; }

for c in pw-link pw-mon jq; do
  command -v "$c" >/dev/null || { log "required command not found: $c"; exit 1; }
done
HAVE_PACTL=0
command -v pactl >/dev/null && HAVE_PACTL=1 || log "pactl not found (pipewire-pulse) — audio routing disabled, MIDI only"
[ -r "$CONFIG" ] || { log "config not readable: $CONFIG"; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { log "config is not valid JSON: $CONFIG"; exit 1; }

cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }   # read a value from the config

declare -A AL_SEEN          # trigger devices seen on the previous pass
AL_LAST_LAUNCH=-1000        # SECONDS at last launch (debounce)

# ── PipeWire helpers ───────────────────────────────────────────────────────
# Emit "ID<TAB>NAME" lines, stripping the trailing (capture)/(playback) tag.
# $1 = o (source/output ports) | i (sink/input ports)
_ports() {
  pw-link -I "-$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/; s/ \((capture|playback)\)$//'
}
src_exact()  { _ports o | awk -F'\t' -v n="$1" '$2==n      { print $1; exit }'; }   # exact source
src_sub()    { _ports o | awk -F'\t' -v n="$1" 'index($2,n){ print $1; exit }'; }   # substring source
sink_exact() { _ports i | awk -F'\t' -v n="$1" '$2==n      { print $1; exit }'; }   # exact sink

mklink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link    "$1" "$2" 2>/dev/null; return 0; }
rmlink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link -d "$1" "$2" 2>/dev/null; return 0; }

# ── default-based audio ─────────────────────────────────────────────────────
# IDs and names of a plugin's output ports, sorted by name
# (output_1, output_2, ...). Links must use IDs because applications such as
# Chromium can expose several ports with the exact same name.
plugin_outs() { _ports o | awk -F'\t' -v n="$1:" 'index($2,n)==1' | sort -t $'\t' -k2,2; }

# Input ports currently fed by node $1's capture ports (i.e. who reads a source).
source_consumers() {
  pw-link -I -o -l 2>/dev/null | awk -v def="$1:" '
    /\|->/ {
      if (cur) {
        l=$0; sub(/^.*\|->[[:space:]]*/, "", l)
        id=l; sub(/[[:space:]].*$/, "", id)
        name=l; sub(/^[0-9]+[[:space:]]+/, "", name)
        sub(/ \((capture|playback)\)$/, "", name)
        print id "\t" name
      }
      next
    }
    {
      name=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", name)
      sub(/ \((capture|playback)\)$/, "", name)
      cur = (index(name, def) == 1)
    }
  '
}

# Desired "OUTPORT<TAB>INPORT" audio links for one plugin: its outputs go to the
# default sink's playback ports AND into every consumer of the default source.
desired_audio_links() {
  [ "$HAVE_PACTL" = 1 ] || return 0
  local plugin="$1" L R sink src port port_id cport cport_id
  local -a outs; mapfile -t outs < <(plugin_outs "$plugin")
  [ "${#outs[@]}" -eq 0 ] && return 0
  L="${outs[0]%%$'\t'*}"
  R="${outs[1]:-${outs[0]}}"; R="${R%%$'\t'*}"   # left, right (mono duplicates)

  # 1) default output (speakers / headphones)
  sink=$(pactl get-default-sink 2>/dev/null)
  if [ -n "$sink" ] && [ "$sink" != "@DEFAULT_SINK@" ]; then
    while IFS=$'\t' read -r port_id port; do
      case "$port" in
        *FR|*_R|*-R) printf '%s\t%s\n' "$R" "$port_id" ;;
        *FL|*_L|*-L) printf '%s\t%s\n' "$L" "$port_id" ;;
      esac
    done < <(_ports i | awk -F'\t' -v n="$sink:" 'index($2,n)==1')
  fi

  # 2) default input's consumers (mic mix — no virtual device)
  src=$(pactl get-default-source 2>/dev/null)
  if [ -n "$src" ] && [ "$src" != "@DEFAULT_SOURCE@" ]; then
    while IFS=$'\t' read -r cport_id cport; do
      [ -z "$cport_id" ] && continue
      case "$cport" in
        "$plugin:"*) continue ;;                       # never feed ourselves
        *FR|*_R|*-R|*[Rr]ight*) printf '%s\t%s\n' "$R" "$cport_id" ;;
        *FL|*_L|*-L|*[Ll]eft*)  printf '%s\t%s\n' "$L" "$cport_id" ;;
        *) printf '%s\t%s\n' "$L" "$cport_id"; printf '%s\t%s\n' "$R" "$cport_id" ;;  # mono/unknown -> sum
      esac
    done < <(source_consumers "$src")
  fi
}

# Existing "OUTPORT<TAB>INPORT" links currently coming from a plugin's outputs.
existing_audio_links() {
  local plugin="$1"
  pw-link -I -o -l 2>/dev/null | awk -v plugin="$plugin:" '
    /\|->/ {
      if (cur) {
        l=$0; sub(/^.*\|->[[:space:]]*/, "", l)
        dst=l; sub(/[[:space:]].*$/, "", dst)
        print cur "\t" dst
      }
      next
    }
    {
      id=$1
      name=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", name)
      sub(/ \((capture|playback)\)$/, "", name)
      if (index(name, plugin) == 1) cur=id; else cur=""
    }
  '
}

# Reconcile one plugin's output links to exactly the desired set (drop stale,
# add missing). Speaker and mic-mix links are reconciled together, so they
# never tear each other down.
apply_audio() {
  local plugin="$1" desired existing link a b
  desired=$(desired_audio_links "$plugin")
  existing=$(existing_audio_links "$plugin")
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    printf '%s\n' "$desired" | grep -qxF -- "$link" && continue
    IFS=$'\t' read -r a b <<< "$link"; rmlink "$a" "$b"
  done <<< "$existing"
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    printf '%s\n' "$existing" | grep -qxF -- "$link" && continue
    IFS=$'\t' read -r a b <<< "$link"; mklink "$a" "$b"
  done <<< "$desired"
}

# ── auto-launch: open Carla when a trigger MIDI controller connects ────────
# Edge-triggered: fires only when a device goes absent -> present (so closing
# Carla while the controller stays plugged won't relaunch it), and only if the
# target process isn't already running.
auto_launch() {
  [ "$(cfg '.auto_launch.enabled // false')" = true ] || return 0
  local dev proc cmd newly=0
  while IFS= read -r dev; do
    [ -z "$dev" ] && continue
    if [ -n "$(src_sub "$dev")" ]; then
      [ "${AL_SEEN[$dev]:-0}" = 1 ] || newly=1
      AL_SEEN[$dev]=1
    else
      AL_SEEN[$dev]=0
    fi
  done < <(cfg '.auto_launch.when_connected[]?')
  [ "$newly" -eq 1 ] || return 0

  proc=$(cfg '.auto_launch.process // "carla"')
  pgrep -x "$proc" >/dev/null 2>&1 && return 0           # already running
  [ $((SECONDS - AL_LAST_LAUNCH)) -lt 15 ] && return 0   # debounce relaunch
  AL_LAST_LAUNCH=$SECONDS
  cmd=$(cfg '.auto_launch.command // "carla"')
  log "MIDI controller connected and '$proc' not running -> launching: $cmd"
  # GUI apps need the graphical-session env (DISPLAY/WAYLAND_DISPLAY/etc). The
  # daemon may have started before the compositor imported those into the user
  # manager, so its own environment can lack them. Pull the current values from
  # the user systemd manager so Carla can actually reach the display.
  local -a genv=()
  while IFS= read -r _e; do genv+=("$_e"); done < <(
    systemctl --user show-environment 2>/dev/null \
      | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)=')
  setsid env "${genv[@]}" sh -c "$cmd" >/dev/null 2>&1 </dev/null &
}

# ── core: bring the live graph in line with the config ─────────────────────
reconcile() {
  local n i plugin port target chosen dev sid
  n=$(cfg '(.samplers // []) | length'); [ -z "$n" ] && n=0
  for ((i = 0; i < n; i++)); do
    plugin=$(cfg ".samplers[$i].plugin")
    [ -z "$plugin" ] || [ "$plugin" = null ] && continue

    # ── MIDI: priority failover (exclusive) ──────────────────────────────
    port=$(cfg ".samplers[$i].midi.port // \"events-in\"")
    target=$(sink_exact "$plugin:$port")
    if [ -n "$target" ]; then
      chosen=""
      while IFS= read -r dev; do
        [ -z "$dev" ] && continue
        sid=$(src_sub "$dev")
        [ -z "$sid" ] && continue
        if [ -z "$chosen" ]; then chosen="$sid"; mklink "$sid" "$target"
        else rmlink "$sid" "$target"; fi
      done < <(cfg ".samplers[$i].midi.priority[]?")
      if [ -z "$chosen" ] && [ "$(cfg ".samplers[$i].midi.auto_add // false")" = true ]; then
        local id name
        while IFS=$'\t' read -r id name; do
          case "$name" in *"Midi Through"*|"$plugin:"*) continue ;; esac
          mklink "$id" "$target"; break
        done < <(_ports o | awk -F'\t' 'tolower($2) ~ /midi/')
      fi
    fi

    # ── AUDIO: default sink + default source consumers ───────────────────
    apply_audio "$plugin"
  done

  auto_launch
}

# ── lifecycle: drop the mic-mix links when the daemon stops ─────────────────
# Speaker links are harmless to leave; the mic-mix links are removed so nothing
# keeps hearing Carla after we exit.
cleanup() {
  [ "$HAVE_PACTL" = 1 ] || return 0
  local n i plugin src cport_id L R
  src=$(pactl get-default-source 2>/dev/null)
  [ -z "$src" ] || [ "$src" = "@DEFAULT_SOURCE@" ] && return 0
  n=$(cfg '(.samplers // []) | length'); [ -z "$n" ] && n=0
  for ((i = 0; i < n; i++)); do
    plugin=$(cfg ".samplers[$i].plugin")
    [ -z "$plugin" ] || [ "$plugin" = null ] && continue
    local -a outs; mapfile -t outs < <(plugin_outs "$plugin")
    [ "${#outs[@]}" -eq 0 ] && continue
    L="${outs[0]%%$'\t'*}"
    R="${outs[1]:-${outs[0]}}"; R="${R%%$'\t'*}"
    while IFS=$'\t' read -r cport_id _; do
      [ -z "$cport_id" ] && continue
      rmlink "$L" "$cport_id"; rmlink "$R" "$cport_id"
    done < <(source_consumers "$src")
  done
}
trap cleanup EXIT INT TERM

# ── run: initial pass, then react to graph + default changes (debounced) ────
# pw-mon emits thousands of param-update lines per second, and every pw-link the
# daemon runs registers a short-lived Client — reacting to those would spin the
# CPU and self-trigger forever. So in C (awk) we wake the shell ONLY when a
# Node/Port/Device is added or removed. pactl subscribe adds wake-ups for
# default input/output changes (a metadata change pw-mon doesn't surface).
# Bursts are coalesced into one reconcile.
watch_events() {
  pw-mon 2>/dev/null | awk '
    /^(added|removed):/                                  { hot = 1; next }
    /^[a-z]+:/                                           { hot = 0 }
    hot && /type: PipeWire:Interface:(Node|Port|Device)/ { print "graph"; fflush(); hot = 0 }
  ' &
  [ "$HAVE_PACTL" = 1 ] && { pactl subscribe 2>/dev/null | awk '/on server/ { print "default"; fflush() }' & }
  wait
}

log "starting; config=$CONFIG"
reconcile
watch_events | while IFS= read -r _; do
  while IFS= read -r -t 0.4 _; do :; done
  reconcile
done
