# Glow — plan

A native macOS menu-bar app that controls a Wipro (Tuya-based) Wi-Fi smart bulb **directly over the
home network**: no cloud, no Python, no vendor app in the loop once the bulb's key is known.

## Goals

1. Every colour, reachable interactively (colour wheel + swatches + brightness).
2. **Whitish yellow (warm white) is the main segment**: the first thing on screen, one tap away, with
   a warmth slider and a saveable "My Glow" favourite.
3. Fast and local: commands go Mac → bulb over TCP in a few milliseconds.
4. One extra "smart bulb app" feature in v1: **Natural Light** (circadian lighting, inspired by Philips
   Hue). Everything else goes on the roadmap below.
5. Repo is publishable: no secrets in git, setup steps documented, reproducible build.

## Architecture

```
┌────────────────────────────┐      ┌─────────────────────────────┐
│ Glow.app (SwiftUI)         │      │ glowctl (CLI)               │
│  MenuBarExtra panel        │      │  status / on / off / colour │
│  BulbModel (@Observable)   │      │  white / natural            │
│  NaturalLight engine       │      └──────────────┬──────────────┘
└──────────────┬─────────────┘                     │
               └────────────────┬──────────────────┘
                        ┌───────▼────────┐
                        │ TuyaKit        │  pure Swift, CryptoKit + Network.framework
                        │  frame codec   │  Tuya LAN protocol 3.5 (AES-GCM, 0x6699 frames)
                        │  session key   │  HMAC-SHA256 nonce handshake
                        │  Bulb API      │  datapoints 20–26
                        └───────┬────────┘
                                │ TCP 6668 (LAN)
                        ┌───────▼────────┐
                        │ Wipro bulb     │
                        └────────────────┘

Key setup (one time): scripts/setup-key.sh → Tuya IoT cloud → ~/.config/glow/bulb.json (mode 600)
```

### Why pure Swift instead of wrapping tinytuya
- The `.app` runs on any Mac with no Python install, and the same `TuyaKit` can later be reused
  unchanged in an iPhone app (CryptoKit and Network.framework exist on iOS).
- tinytuya is still used **once**, by the setup script, to fetch the key from Tuya's cloud.

### Protocol 3.5 summary (ported from tinytuya, verified against the real bulb)
| Step | What happens |
|---|---|
| Connect | TCP to `<bulb-ip>:6668` |
| Handshake 1 | Send cmd 3 with a random 16-byte nonce `A`, AES-GCM encrypted with the local key |
| Handshake 2 | Bulb replies cmd 4: its nonce `B` + `HMAC-SHA256(localKey, A)` (proves it knows the key) |
| Handshake 3 | Send cmd 5: `HMAC-SHA256(localKey, B)` (proves we know the key) |
| Session key | `AES-GCM(localKey, iv=A[0..12]).encrypt(A xor B)` → 16-byte key for this connection |
| Status | cmd 16 (`DP_QUERY_NEW`) with `{}` |
| Control | cmd 13 (`CONTROL_NEW`): `"3.5"+12×0x00` + `{"protocol":5,"t":<unix>,"data":{"dps":{…}}}` |
| Frame | `00006699 · 0000 · seq · cmd · len` + `iv(12) · ciphertext · tag(16)` + `00009966`; header bytes 4–18 are the GCM AAD |
| Replies | decrypted payload starts with a 4-byte return code, then optionally `"3.5"+12×0x00`, then JSON |

### Datapoints on this bulb
| DP | Code | Values |
|---|---|---|
| 20 | `switch_led` | bool |
| 21 | `work_mode` | `white` · `colour` · `scene` · `music` |
| 22 | `bright_value_v2` | 10–1000 |
| 23 | `temp_value_v2` | 0 (warm, ~2700 K) – 1000 (cool, ~6500 K) |
| 24 | `colour_data_v2` | hex `hhhhssssvvvv`: h 0–360, s 0–1000, v 0–1000 |
| 25 | `scene_data_v2` | built-in scenes (1–8) |
| 26 | `countdown_1` | seconds until toggle (0–86400) |
| 27/28 | `music_data` / `control_data` | real-time, non-persisted colour (good for effects) |
| 30–32 | `rhythm_mode` / `sleep_mode` / `wakeup_mode` | native on-bulb fades (raw) |

## UI (see `sketch.html`)

Menu-bar panel, ~340 pt wide, three stacked sections:

1. **Header**: bulb name, connection dot, big power switch.
2. **Warm White (hero)**: large glowing card showing the current white. Sliders: *Warmth* (warm ↔ cool,
   shown in Kelvin) and *Brightness*. Preset chips: **My Glow** (whitish yellow, editable via
   "Save as My Glow"), Candle, Reading, Daylight.
3. **Colour**: draggable hue/saturation wheel, brightness slider, 16 swatches.
4. **Natural Light** toggle with "what it's doing now" (e.g. *Evening · 3100 K · 70%*).

## Natural Light (the v1 extra feature)

Inspired by Hue's *Natural Light* scene: when enabled, the bulb follows the time of day:
cool and bright around midday, warmer through the evening, very warm and dim late at night.
- Keyframes (local time) interpolated linearly, re-applied every minute.
- Only touches the bulb when it is on; turning it on while enabled jumps to the right white.
- Any manual change (colour, slider, preset) pauses it, like Hue does.

## Milestones

- [x] M0 Prove LAN control with tinytuya (red, then yellow)
- [x] M1 Repo skeleton, plan, sketch, `.gitignore` for secrets
- [x] M2 `TuyaKit`: codec + handshake, verified with test vectors generated from tinytuya (7 tests)
- [x] M3 `glowctl` CLI, verified against the real bulb (status, blue, #ff6600, My Glow)
- [x] M4 SwiftUI menu-bar app: warm-white hero, colour wheel, swatches, power
- [x] M5 Natural Light
- [x] M6 `.app` bundle build script (+ generated icon), setup script, README, docs/how-we-got-the-key.md
- [ ] M7 Commit + push to GitHub (needs your git identity and a remote)

## Shipping / running it elsewhere

| Way | Effort | Notes |
|---|---|---|
| `Glow.app` in `~/Applications` | done in M6 | ad-hoc signed; fine for your own Mac |
| Share the `.app` with friends | zip it | they right-click → Open once (unsigned); each needs their own bulb key |
| Proper distribution | Apple Developer ID ($99/yr) + notarization, Homebrew cask | no Gatekeeper warning |
| `glowctl` CLI | done in M3 | Terminal, scripts, `launchd`, cron, Claude Code hooks |
| macOS Shortcuts / Siri on Mac | small | "Run Shell Script → glowctl colour red"; bind to a keyboard shortcut |
| App Intents in Glow.app | medium | native Shortcuts/Siri/Spotlight actions, Control Center control (macOS 15) |
| Raycast / Alfred | small | script command wrapping `glowctl` |
| iPhone app | medium | reuse `TuyaKit` in an iOS SwiftUI target; needs Xcode (free 7-day signing or $99/yr) |
| HomeKit (iPhone, Watch, Siri, Control Center) | medium | Homebridge + a Tuya plugin on an always-on Mac / Raspberry Pi |
| Web dashboard | small | tiny HTTP server on the Mac/Pi → control from any phone browser on the Wi-Fi |
| Alexa / Google | none | still works through Smart Life in parallel |

## Feature roadmap (inspired by Hue, LIFX, Govee, Nanoleaf, WiZ, Yeelight)

| Feature | Inspired by | How it would work here |
|---|---|---|
| **Natural Light** (v1) | Hue | time-of-day white curve |
| Scenes & palettes (Sunset, Ocean, Forest…) | Hue, Govee | saved HSV/white sets; cycle via DP 28 |
| Sunrise wake-up / sunset wind-down | Hue routines, WiZ | slow fade over 15–30 min, or native `wakeup_mode`/`sleep_mode` DPs |
| Sleep timer | every app | native `countdown_1` (DP 26), works even if the Mac sleeps |
| Effects: candle, breathe, colour loop, party | LIFX, Govee | stream to `control_data` (DP 28) so nothing is persisted |
| Music sync | Govee, LIFX | microphone FFT → hue/brightness, or bulb's native music mode |
| Screen sync | Hue Sync, Govee DreamView | ScreenCaptureKit average colour → bulb |
| Now-playing album colour | Govee | dominant colour of Apple Music / Spotify artwork |
| Focus / Pomodoro light | Nanoleaf | warm during focus, pulse on break |
| Meeting light | Busy-light apps | red while a calendar event / camera is active |
| Claude Code status light | claude-lightbulb-hooks | hooks → `glowctl` (green working, red needs you) |
| Mac presence | Hue "away" | lock/sleep → off, unlock → on; vacation random on/off |
| Eyedropper | — | pick any on-screen colour (NSColorSampler) |
| Schedules | every app | time-based on/off/colour, also native `cycle_timing` |
| Groups / rooms | Hue | second bulb at `.254` once it's moved to Smart Life |
| Global hotkeys, desktop widget | — | ⌥⌘L toggle, WidgetKit widget |
| Auto-discover IP | tinytuya scan | listen for the bulb's UDP 6667 broadcast if DHCP moves it |
