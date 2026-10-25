# Glow

A native macOS menu-bar app (and CLI) that controls a **Wipro smart bulb directly over your home
Wi-Fi**: no cloud, no vendor app, no Python at runtime.

- **Warm White first**: whitish-yellow card with warmth/brightness sliders and a saveable ★ **My Glow**
  preset (3080 K, 85%), plus Candle / Reading / Daylight
- **Every colour**: hue/saturation wheel + 16 swatches
- **Natural Light**: follows the time of day, like Philips Hue
- **`glowctl`** CLI, including a "Claude is done" light for Claude Code
- Pure-Swift Tuya LAN **protocol 3.5**, tested byte for byte against [tinytuya](https://github.com/jasonacox/tinytuya)

Sketch: [`sketch.html`](sketch.html) · Plan & roadmap: [`PLAN.md`](PLAN.md)

## The bulb: Wipro, built on Tuya

Tested with a **Wipro Wi-Fi smart bulb** (Wipro Smart Home multicolour range; reports as *"Smart Bulb
12.5W"*). Wipro rebadges **[Tuya](https://www.tuya.com/)**: the chip, firmware, cloud and even the
Wipro Smart Home app are Tuya's. So the bulb speaks Tuya's local protocol (TCP 6668), and every
command must be encrypted with a per-device **local key** that only the owning Tuya account can
provide. We used:

- **[Tuya IoT Developer Platform](https://iot.tuya.com)**: once, to fetch the local key
- **[Smart Life](https://apps.apple.com/in/app/smartlife-smart-living/id1115101477)**: Tuya's own app, the only kind the platform can link to
- **[tinytuya](https://github.com/jasonacox/tinytuya)**: discovery, key fetch, and the reference for our Swift port

After setup, Glow never talks to Tuya again.

## What we did

1. Found the bulb on the Wi-Fi (ARP sweep → TCP 6668 open; `tinytuya scan` → Tuya, protocol 3.5).
2. Without the local key the bulb rejects everything, so we needed the key.
3. **Wipro app: dead end.** The Tuya project links devices via a QR code that only Smart Life / Tuya
   Smart can scan; with the Wipro app it expired, so the bulb (and its key) stayed inaccessible
   (`1106 permission deny`).
4. Moved the bulb to **Smart Life** (region India) and linked it to a Tuya cloud project (India Data Center).
5. Fetched the key with the project's Access ID/Secret, then built Glow.

Details and dead ends: [docs/how-we-got-the-key.md](docs/how-we-got-the-key.md).

## Quick start

Needs macOS 14+, Swift 5.9+ (Command Line Tools are enough), and the Mac on the same network as the bulb.

```bash
git clone https://github.com/Nischay19/wipro-smart-bulb-app glow && cd glow
scripts/setup-key.sh          # one time: Tuya Access ID/Secret -> ~/.config/glow/bulb.json
scripts/build-app.sh --install
open ~/Applications/Glow.app  # 💡 appears in the menu bar
```

Allow **Local Network** access when macOS asks.

## CLI

```bash
glowctl status | on | off | toggle
glowctl glow                    # whitish yellow
glowctl white 2700K 40
glowctl colour red              # or '#ff6600' 60; list names: glowctl colours
glowctl natural
glowctl notify                  # 2 s "done" signal, then restores the bulb's state
```

### "Claude is done" light

Off → warm candle flicker; on → brightness pulse; either way the bulb goes back to exactly how it was.
Add to `~/.claude/settings.json`:

```json
"hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "\"$HOME/.local/bin/glowctl\" notify >/dev/null 2>&1 || true",
  "async": true, "timeout": 15 } ] } ] }
```

## Project layout

```
Sources/TuyaKit/   protocol 3.5, handshake, bulb datapoints, Natural Light
Sources/glowctl/   CLI
Sources/Glow/      SwiftUI menu-bar app
Tests/             tinytuya-generated test vectors (swift test)
scripts/           build-app.sh, setup-key.sh
```

## Notes

- If the router gives the bulb a new IP, re-run `scripts/setup-key.sh`.
- The key lives only in `~/.config/glow/bulb.json` (mode 600), never in the repo.

Not affiliated with Wipro or Tuya. For controlling devices you own.
