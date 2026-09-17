# Carla-MIDI-Daemon

A tiny background daemon that automatically wires your MIDI controllers **and
audio** for [Carla](https://github.com/falkTX/Carla) plugins on Linux/PipeWire.

Manual patchbay connections in Carla are fragile: any time a device connects or
disconnects, PipeWire rebuilds its node graph and your hand-made links vanish.
This daemon watches the graph and re-asserts the right connections instantly, so
your rig "just works" no matter what gets plugged in or unplugged.

## Features

- **MIDI priority/failover** — map several controllers to a Carla plugin (a
  *sampler*) in priority order. The highest-priority connected controller drives
  it; unplug it and it falls back to the next, plug it back and it switches back.
- **Audio to the default output** — each plugin's outputs are routed to the
  current **default sink** (your speakers/headphones). Change your default output
  and it re-routes live. No per-device config.
- **Mic mix (no virtual device)** — mix each plugin's audio into your microphone
  by linking its output into whatever app is capturing the **current default
  source**, so callers/recorders hear mic + Carla. The default mic is never
  changed and no device appears/disappears, so apps that own the default (e.g.
  WiVRn) keep working. Links are removed when the daemon stops.
- **Follows the defaults** — nothing is hardcoded to a specific device (or to
  EasyEffects). Switch your default input/output and the daemon re-wires. For the
  mic mix to reach an app, point that app's input at **Default**.
- **Auto-launch Carla** — open Carla automatically when a controller is plugged
  in.
- **auto_add** (optional) — grab any connected MIDI device when none of the
  listed ones are present.
- **Event-driven** — wakes only on real Node/Port/Device changes (filtered from
  PipeWire's firehose in C) and default input/output changes (`pactl subscribe`);
  ~0% CPU at idle. No polling.

## Requirements

- PipeWire with `pw-link` and `pw-mon`
- `jq`
- `pactl` (for all audio routing; from `pipewire-pulse`). Without it the daemon
  still does MIDI, but no audio wiring.
- [Carla](https://github.com/falkTX/Carla)
- A user systemd session (runs as a `--user` service)

## Install

```bash
git clone https://github.com/DevL0rd/Carla-MIDI-Daemon
cd Carla-MIDI-Daemon
./install.sh
```

The installer is **idempotent**. It installs the daemon to
`~/.local/bin/carla-midi-daemon`, a user service to
`~/.config/systemd/user/carla-midi-daemon.service`, creates
`~/.config/carla-midi-daemon/config.json` from the example **only if absent**
(your edits are never overwritten), and enables + (re)starts the service.

## Configure

All configuration is **JSON**, at `~/.config/carla-midi-daemon/config.json`:

```json
{
  "samplers": [
    {
      "plugin": "BitsonicSampler",
      "midi": {
        "port": "events-in",
        "auto_add": false,
        "priority": ["USB func for MIDI", "CN29: Bluetooth"]
      }
    }
  ],
  "auto_launch": {
    "enabled": true,
    "command": "carla $HOME/.config/carla-midi-daemon/BitsonicSampler.carxp",
    "process": "carla",
    "when_connected": ["USB func for MIDI", "CN29: Bluetooth"]
  }
}
```

**Audio is not configured** — it always follows the system default input and
output (see [Audio](#audio) below). You only configure MIDI and auto-launch.

**Name matching:** MIDI devices are matched as a **substring** of the PipeWire
port name, so a recognizable fragment is enough. List names with:

```bash
pw-link -o | grep -i midi     # MIDI controllers
pactl get-default-sink        # where Carla audio is sent
pactl get-default-source      # the mic the mix follows
```

### `samplers[]`

| Field | Meaning |
|-------|---------|
| `plugin` | Plugin's PipeWire node name as shown in Carla (e.g. `BitsonicSampler`). |
| `midi.port` | Plugin's MIDI input port. Default `events-in`. |
| `midi.priority[]` | MIDI devices, ordered — first = highest priority. |
| `midi.auto_add` | `true` to grab any MIDI device when none listed are present. |

### Audio

There is nothing to configure. For every `plugin` in `samplers[]`, the daemon
takes its output ports (`output_1`/`output_2`) and, on every graph or default
change:

- routes them to the current **default sink** — your speakers/headphones; and
- mixes them into every consumer of the current **default source** — so anything
  capturing your mic hears mic + Carla, **without a virtual device**. The default
  mic is never changed and nothing appears/disappears, so apps that own the
  default (e.g. WiVRn) are unaffected.

A mono mic fans both Carla channels into the mono consumer; a stereo consumer
gets L/R by position. Speaker and mic-mix links are reconciled together, so they
never fight over the plugin's output ports. The mic-mix links are torn down when
the daemon stops.

Because it follows whatever is capturing the *default* source, it works with or
without an effects processor (e.g. EasyEffects) in the chain — the daemon never
references one. **For an app to receive the mix, set that app's input device to
"Default"** (not pinned to a specific node). Switch your default mic or output at
any time and the daemon re-routes live.

### `auto_launch`

Opens Carla when a controller is plugged in. **Edge-triggered**: fires only on an
absent→present transition, so closing Carla while the controller stays plugged
won't relaunch it. Skipped if `process` is already running.

| Field | Meaning |
|-------|---------|
| `enabled` | On by default. |
| `command` | What to run (e.g. `carla`, or `carla /path/to/project.carxp`). |
| `process` | Process name checked with `pgrep -x` to avoid double launches. |
| `when_connected[]` | MIDI device substrings that trigger the launch. |

A starter Carla project, **`BitsonicSampler.carxp`**, is bundled and installed to
`~/.config/carla-midi-daemon/`; the default `command` opens it. It contains only
the plugin (and its preset) — no patchbay connections, because the daemon makes
all the connections itself once the plugin loads. Save over that file from Carla
to customize what auto-launch opens (the installer won't overwrite it).

Apply config changes with:

```bash
systemctl --user restart carla-midi-daemon
```

## Manage

```bash
systemctl --user status  carla-midi-daemon
journalctl --user -u carla-midi-daemon -f
systemctl --user restart carla-midi-daemon
```

## Uninstall

```bash
./uninstall.sh            # remove daemon + service, keep config
./uninstall.sh --purge    # also delete ~/.config/carla-midi-daemon
```

The daemon removes its mic-mix links on shutdown, so nothing is left dangling.

## License

Released into the public domain — do whatever you like with it.
