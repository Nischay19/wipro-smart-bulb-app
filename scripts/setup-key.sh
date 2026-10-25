#!/usr/bin/env bash
# One-time: creates a private venv with tinytuya and runs the key setup wizard.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
  .venv/bin/pip install -q --disable-pip-version-check "tinytuya>=1.17"
fi
exec .venv/bin/python setup_key.py "$@"
