# Glow

A native macOS menu-bar app (and CLI) that controls a **Wipro / Tuya Wi-Fi smart bulb directly over
your home network**: no cloud round-trip, no vendor app, no Python at runtime.

- **Warm White first**: a big "whitish yellow" card with warmth + brightness sliders and a saveable
  ★ **My Glow** preset (default 3080 K, 85%), plus Candle / Reading / Daylight.
- **Every colour**: drag a hue/saturation wheel or tap one of 16 swatches; separate colour brightness.
- **Natural Light**: follows the time of day like Philips Hue (cool and bright at midday, warm and dim
  in the evening). Any manual change pauses it.
- **`glowctl`** CLI for scripts, Shortcuts, Raycast, cron, Claude Code hooks…
- Pure-Swift implementation of Tuya's LAN **protocol 3.5** (AES-GCM + HMAC handshake), unit-tested
  byte for byte against [tinytuya](https://github.com/jasonacox/tinytuya).

Design sketch: open [`sketch.html`](sketch.html) in a browser. Plan & roadmap: [`PLAN.md`](PLAN.md).

## The bulb: Wipro, built on Tuya

Glow was built and tested with a **Wipro Wi-Fi smart bulb** (Wipro Smart Home range, the
Alexa/Google-compatible multicolour bulb; the cloud reports it as *"Smart Bulb 12.5W"*, Tuya category `dj`).

Wipro doesn't make its own smart-home stack. The bulb's Wi-Fi chip, firmware and cloud, and the
**Wipro Smart Home** app itself, come from **[Tuya](https://www.tuya.com/)**, a white-label IoT platform
that hundreds of brands rebadge. That is why the bulb speaks Tuya's local protocol on TCP port 6668,
and why Tuya's tools work with it:

- **[Tuya IoT Developer Platform](https://iot.tuya.com)**: the official cloud console. We used it once,
  to fetch the bulb's per-device **local key** (the AES key every LAN command is encrypted with).
- **[Smart Life app](https://apps.apple.com/in/app/smartlife-smart-living/id1115101477)**: Tuya's own
  consumer app; the only kind of app the developer platform can link to.
- **[tinytuya](https://github.com/jasonacox/tinytuya)**: open-source Python library for Tuya's LAN
  protocol. Used to discover the bulb, fetch the key, and as the reference our Swift port is tested
  against.

**Why Tuya at all?** The bulb only accepts commands encrypted with its local key, and only the Tuya
cloud account that owns the bulb can hand that key out. Going through Tuya's official developer
platform is the supported way to get it. After that, Glow never talks to Tuya again: control is
Mac → bulb over your Wi-Fi.

## What we did (in brief)

1. **Found the bulb on the Wi-Fi**: ping sweep + ARP table, spotted the one non-randomized MAC with
   TCP **6668** open (Tuya's port); `tinytuya scan` confirmed a Tuya device on **protocol 3.5**.
2. **Learned we need its local key**: without it the bulb rejects everything (`914 Check device key`).
3. **Tried the Wipro app route: dead end.** A Tuya developer project links devices by scanning a QR
   code with the app the bulb is paired in, but that QR is **only scannable by Tuya's own apps (Smart
   Life / Tuya Smart)**. With the Wipro Smart Home app it just expired, so the project couldn't see the
   bulb and every cloud call returned `1106 permission deny`. The key isn't reachable through the
   Wipro app. (An Android-only Bluetooth route exists, [wipro-bulb-local](https://github.com/divyanshchandhok/wipro-bulb-local),
   but we're on iPhone.)
4. **Moved the bulb to Smart Life** (same bulb, same Tuya backend), region **India**.
5. **Linked Smart Life to a Tuya cloud project** (India Data Center) by scanning the project's QR.
6. **Fetched the local key** with the project's Access ID/Secret → the bulb went red, then yellow.
7. **Built Glow**: ported protocol 3.5 to pure Swift (tested byte for byte against tinytuya), wrote
   the `glowctl` CLI and the SwiftUI menu-bar app.

Full write-up with commands and dead ends: [docs/how-we-got-the-key.md](docs/how-we-got-the-key.md).

## Requirements

- macOS 14+ (Apple Silicon or Intel), Swift 5.9+ (Xcode or just the Command Line Tools)
- A Tuya-based bulb speaking protocol 3.5, reachable on the same network as the Mac
- Its **local key**: see [docs/how-we-got-the-key.md](docs/how-we-got-the-key.md)

## Quick start

```bash
git clone <this repo> glow && cd glow
scripts/setup-key.sh          # one time: Tuya Access ID/Secret -> ~/.config/glow/bulb.json (mode 600)
scripts/build-app.sh --install
open ~/Applications/Glow.app  # click the 💡 in the menu bar
```

The first time, macOS asks **"Allow Glow to find devices on local networks?"**: click **Allow**
(or enable it later under System Settings → Privacy & Security → Local Network).

### CLI

```bash
glowctl status
glowctl glow                    # whitish yellow
glowctl white 2700K 40          # warm, 40%
glowctl colour red              # names: glowctl colours
glowctl colour '#ff6600' 60
glowctl natural                 # apply the Natural Light white for right now
glowctl on | off | toggle
```

`scripts/build-app.sh --install` puts `glowctl` in `~/.local/bin`.

### "Claude is done" light (Claude Code hook)

`glowctl notify` gives a ~2 second signal and then leaves the bulb exactly as it was:
- **bulb off** → warm candle flicker, then off again (its remembered colour/white is restored too)
- **bulb on** → brightness pulses, then the original colour or white comes back

Wire it to Claude Code's `Stop` event (fires whenever Claude finishes responding) in
`~/.claude/settings.json`. `async` keeps it from ever delaying Claude:

```json
"hooks": {
  "Stop": [
    { "hooks": [
      { "type": "command",
        "command": "\"$HOME/.local/bin/glowctl\" notify >/dev/null 2>&1 || true",
        "async": true, "timeout": 15 }
    ]}
  ]
}
```

## Project layout

```
Sources/TuyaKit/     protocol 3.5 codec, session handshake, bulb datapoints, Natural Light curve
Sources/glowctl/     command-line tool
Sources/Glow/        SwiftUI MenuBarExtra app
Tests/TuyaKitTests/  test vectors generated with tinytuya
scripts/             build-app.sh (bundle + icon + ad-hoc sign), setup-key.sh (key wizard)
docs/                how we found the bulb and got its key
```

```bash
swift test                                # protocol tests
swift run glowctl status                  # CLI from source
.build/debug/Glow --snapshot panel.png    # render the panel to an image (dev aid)
```

## Notes

- The bulb typically accepts only a couple of simultaneous LAN connections; if `glowctl` and the app
  fight, quit one.
- If the router hands the bulb a new IP, re-run `scripts/setup-key.sh` (auto-discovery is on the roadmap).
- Secrets live only in `~/.config/glow/bulb.json`; `.gitignore` blocks key files from the repo.

Not affiliated with Wipro or Tuya. For controlling devices you own.
