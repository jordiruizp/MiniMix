#!/usr/bin/env bash
# Construye build/MiniMix.app desde el paquete App (sin Xcode).
# Uso: scripts/bundle-app.sh [debug|release]
# Firma: $MINIMIX_SIGN_IDENTITY si está definida; si no, el certificado local «MiniMix Local» si existe
# (identidad estable: los bookmarks de los proyectos sobreviven a las actualizaciones); si no, ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cfg="${1:-debug}"
swift build --package-path App -c "$cfg" --product MiniMix
bin="$(swift build --package-path App -c "$cfg" --show-bin-path)"
app=build/MiniMix.app
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MiniMix" "$app/Contents/MacOS/"
cp App/Resources/Info.plist "$app/Contents/"
find "$bin" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$app/Contents/Resources/" \;
identity="${MINIMIX_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"MiniMix Local\""; then
  identity="MiniMix Local"
fi
codesign --force --timestamp=none --sign "${identity:--}" --entitlements App/Resources/MiniMix.entitlements "$app"
echo "  firma: ${identity:-ad-hoc}"
echo "✔ $app"
