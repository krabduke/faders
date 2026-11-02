#!/bin/zsh
# Builds Faders.app and uploads it as a GitHub release: scripts/release.sh v0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?usage: scripts/release.sh vX.Y.Z}"
./build.sh
mkdir -p dist
rm -f dist/Faders.zip
ditto -c -k --keepParent build/Faders.app dist/Faders.zip
gh release create "$tag" dist/Faders.zip --title "Faders $tag" --notes "Download Faders.zip, unzip, and move Faders.app to Applications. Or run the one-line installer from the README."
