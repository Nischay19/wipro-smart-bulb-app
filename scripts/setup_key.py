"""One-time setup: fetch your bulb's local key from your Tuya IoT cloud project and write
~/.config/glow/bulb.json (mode 600), which Glow.app and glowctl read.

Prerequisites (see docs/how-we-got-the-key.md):
  * the bulb is paired in the Smart Life app (India region for Indian accounts)
  * a Tuya IoT cloud project on iot.tuya.com in the same data center, with the Smart Life
    account linked (Devices -> Link App Account -> scan the QR from Smart Life)

The Access Secret is used for this one request and never written to disk.
"""
import getpass
import json
import os
import sys

import tinytuya

REGIONS = ("in", "us", "us-e", "eu", "eu-w", "cn", "sg")
CONFIG = os.path.expanduser(os.environ.get("GLOW_CONFIG", "~/.config/glow/bulb.json"))


def ask(prompt, default=None):
    value = input(f"{prompt}{f' [{default}]' if default else ''}: ").strip()
    return value or default


def main():
    print(__doc__)
    region = ask(f"Tuya data center ({'/'.join(REGIONS)})", "in")
    if region not in REGIONS:
        sys.exit(f"Unknown region {region!r}")
    api_key = ask("Access ID / Client ID")
    api_secret = getpass.getpass("Access Secret / Client Secret (hidden): ").strip()
    if not api_key or not api_secret:
        sys.exit("Access ID and Secret are required.")

    cloud = tinytuya.Cloud(apiRegion=region, apiKey=api_key, apiSecret=api_secret)
    devices = cloud.getdevices(verbose=False)
    del api_secret
    if isinstance(devices, dict):
        sys.exit(f"Tuya cloud error: {devices}\n"
                 "Code 1106 means no device is linked to the project yet: link your Smart Life account.")
    lights = [d for d in devices if d.get("key")]
    if not lights:
        sys.exit("The project has no devices with a local key. Link your Smart Life account first.")

    print("\nScanning the LAN for the bulb's IP (about 15 s)...")
    found = tinytuya.deviceScan(False, 15)
    by_id = {v["gwId"]: (ip, v.get("version")) for ip, v in found.items()}

    for i, d in enumerate(lights, 1):
        ip, version = by_id.get(d["id"], ("not found on LAN", None))
        print(f"  {i}. {d.get('name')}  id={d['id']}  ip={ip}  version={version}")
    choice = int(ask("Which device", "1")) - 1
    dev = lights[choice]
    ip, version = by_id.get(dev["id"], (None, None))
    if not ip:
        ip = ask("Bulb IP (not seen on LAN; check your router's client list)")
    if version and version != "3.5":
        print(f"Warning: this bulb speaks protocol {version}; Glow currently implements 3.5 only.")

    config = {"name": dev.get("name") or "Smart Bulb", "id": dev["id"], "ip": ip,
              "key": dev["key"], "version": version or "3.5"}
    os.makedirs(os.path.dirname(CONFIG), mode=0o700, exist_ok=True)
    fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2)
    print(f"\nWrote {CONFIG} (mode 600). Try: glowctl status")


if __name__ == "__main__":
    main()
