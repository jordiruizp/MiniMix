#!/usr/bin/env bash
# Instala build/MiniMix.app en /Applications (sustituye la versión anterior).
# Uso: scripts/install-local.sh   (ejecuta antes scripts/release.sh o bundle-app.sh release)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/MiniMix.app ]] || { echo "✗ falta build/MiniMix.app (scripts/release.sh)"; exit 1; }
pkill -x MiniMix 2>/dev/null || true
rm -rf /Applications/MiniMix.app
cp -R build/MiniMix.app /Applications/
echo "✔ instalada en /Applications/MiniMix.app"
