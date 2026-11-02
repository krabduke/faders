#!/bin/zsh
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/krabduke/faders/main/install.sh | zsh
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> Installing Faders"
curl -fsSL "https://github.com/krabduke/faders/releases/latest/download/Faders.zip" -o "$tmp/Faders.zip"
ditto -x -k "$tmp/Faders.zip" "$tmp"
pkill -x Faders 2>/dev/null || true
rm -rf /Applications/Faders.app
ditto "$tmp/Faders.app" /Applications/Faders.app
xattr -dr com.apple.quarantine /Applications/Faders.app 2>/dev/null || true
open /Applications/Faders.app

cat <<'MSG'

Done. Click the sliders icon in the menu bar. The first time you change an app's
volume, macOS asks to allow "Screen & System Audio Recording": click Allow.
Tick "Open at login" at the bottom of the panel so it survives restarts.
MSG
