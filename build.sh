#!/bin/zsh
# Builds build/Faders.app. Pass --install to copy it to /Applications and relaunch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build/Faders.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Faders "$app/Contents/MacOS/Faders"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Faders || true
  rm -rf /Applications/Faders.app
  cp -R "$app" /Applications/Faders.app
  open /Applications/Faders.app
  echo "Installed and launched /Applications/Faders.app"
fi
