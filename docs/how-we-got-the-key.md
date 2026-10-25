# How we got local control of a Wipro smart bulb

The full path from "there's a bulb on my Wi-Fi" to "my Mac changes its colour directly", including
the dead ends, so you can reproduce it (or skip the dead ends).

## 1. Find the bulb on the network

```bash
# your subnet
ipconfig getifaddr en0                       # e.g. 192.168.1.39 -> subnet 192.168.1.0/24
# ping-sweep so every device lands in the ARP table, then list it
for i in $(seq 1 254); do ping -c1 -W 300 192.168.1.$i >/dev/null & done; wait; arp -a
```

- Phones/laptops use **randomized MACs** (2nd hex digit 2, 6, A or E) for privacy; IoT devices don't,
  so the bulb is one of the few "real" MACs.
- Probing ports showed **TCP 6668** open: Tuya's local-control port. Wipro's smart range is built on
  **Tuya**, a white-label IoT platform (chip, firmware, cloud and app framework).
- `python -m tinytuya scan` confirmed it: Tuya device, **protocol 3.5**, plus its device id.

## 2. Why you need a "local key"

Protocol 3.5 encrypts everything with AES-GCM using a per-device 16-character **local key** that the
Tuya cloud generates when the bulb is paired. Without it the bulb answers every command with
`914 Check device key or version`. The key cannot be guessed (128-bit random); it has to come from the
cloud account that owns the bulb.

## 3. Getting the key

What **didn't** work:
- **Linking the Wipro Smart Home app to a Tuya developer project.** The project's QR code
  (Devices → Link App Account) only accepts Tuya's own apps (Smart Life / Tuya Smart); with the
  Wipro app it just expired. Cloud API calls returned `1106 permission deny`.
- **Pulling the key out of the iPhone app.** iOS sandboxing blocks it, and the app encrypts its API
  bodies on top of TLS, so a proxy only sees ciphertext.
- [`wipro-bulb-local`](https://github.com/divyanshchandhok/wipro-bulb-local) controls the bulb over
  **Bluetooth** and fetches the BLE key by running the Wipro app's signer on an **Android** phone.
  Clever, but needs Android. Its write-up also confirms the Wi-Fi key from the developer cloud works
  for LAN control when the bulb is reachable, which ours was.

What **worked**:
1. Remove the bulb from the Wipro Smart Home app.
2. Install **Smart Life** ([App Store](https://apps.apple.com/in/app/smartlife-smart-living/id1115101477)),
   sign up with region **India**, and pair the bulb (power-cycle on/off ×3 until it blinks fast).
3. On [iot.tuya.com](https://iot.tuya.com): Cloud → Development → Create Cloud Project
   (Smart Home, **India Data Center**). Note the **Access ID** and **Access Secret**.
4. In the project: Devices → Link App Account → Add App Account → scan the QR from
   Smart Life (Me → scan icon) → confirm. The bulb appears under All Devices.
5. Fetch the key: `scripts/setup-key.sh` (asks for the Access ID/Secret, finds the bulb's IP on the LAN,
   writes `~/.config/glow/bulb.json` with mode 600).

Notes:
- The data center must match the app account's region, or the QR link fails.
- Re-pairing the bulb or removing it in Smart Life **rotates the key**; deleting the app does not.
- After you have the key, reset the Access Secret if you shared it anywhere. LAN control only needs the key.
- The cloud project's free trial expiring only affects cloud control; LAN control keeps working.

## 4. Talking to the bulb

The protocol (as implemented in `Sources/TuyaKit`, ported from [tinytuya](https://github.com/jasonacox/tinytuya)):

1. TCP connect to `<ip>:6668`.
2. Send cmd 3 with a random 16-byte nonce A (encrypted with the local key).
3. Bulb replies cmd 4: its nonce B plus `HMAC-SHA256(localKey, A)`, proving it knows the key.
4. Send cmd 5: `HMAC-SHA256(localKey, B)`, proving we do.
5. Session key = `AES-GCM(localKey, iv=A[0..12]).encrypt(A xor B)`.
6. Commands are JSON like `{"protocol":5,"t":…,"data":{"dps":{"21":"colour","24":"000003e803e8"}}}`
   (prefixed with `"3.5"` + 12 zero bytes), sent as cmd 13 inside an AES-GCM frame.

Datapoints on this bulb: 20 power · 21 mode (white/colour/scene/music) · 22 brightness 10–1000 ·
23 warmth 0–1000 · 24 colour `hhhhssssvvvv` · 26 countdown seconds.
