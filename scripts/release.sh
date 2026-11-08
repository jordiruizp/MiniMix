#!/usr/bin/env bash
# T99 (distribución local/manual): compila en release, firma (ver bundle-app.sh) y crea
# build/MiniMix-<versión>.dmg con la app y un acceso a /Applications.
# Uso: scripts/release.sh   (no notariza: la app no se publica)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle-app.sh release
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/MiniMix.app/Contents/Info.plist)"
codesign --verify --deep --strict build/MiniMix.app
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R build/MiniMix.app "$stage/"
ln -s /Applications "$stage/Applications"
dmg="build/MiniMix-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "MiniMix $version" -srcfolder "$stage" -fs HFS+ -format UDZO -quiet "$dmg"
hdiutil verify -quiet "$dmg"
echo "✔ $dmg ($(du -h "$dmg" | cut -f1))"
