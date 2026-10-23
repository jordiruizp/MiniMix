#!/usr/bin/env bash
# Construye build/MiniMix.app desde el paquete App (sin Xcode).
# Uso: scripts/bundle-app.sh [debug|release]   (firma ad-hoc; T99 firma con Developer ID)
set -euo pipefail
cd "$(dirname "$0")/.."
cfg="${1:-debug}"
swift build --package-path App -c "$cfg" --product MiniMix
bin="$(swift build --package-path App -c "$cfg" --show-bin-path)"
app=build/MiniMix.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MiniMix" "$app/Contents/MacOS/"
cp App/Resources/Info.plist "$app/Contents/"
find "$bin" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$app/Contents/Resources/" \;
codesign --force --sign - --entitlements App/Resources/MiniMix.entitlements "$app"
echo "✔ $app"
