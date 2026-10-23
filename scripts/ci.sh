#!/usr/bin/env bash
# Puerta de calidad local = lo mismo que .github/workflows/ci.yml.
# Uso: scripts/ci.sh [paquete...]   (por defecto, todos)
set -euo pipefail
cd "$(dirname "$0")/.."
all=(Packages/Core Packages/Render Packages/Media Packages/Audio Packages/Output Packages/Persistence App Tests)
pkgs=("${@:-${all[@]}}")
if command -v swiftlint >/dev/null; then
  echo "▶ swiftlint"
  if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then export DYLD_FRAMEWORK_PATH="$(xcode-select -p)/usr/lib"; fi
  swiftlint lint --strict --quiet
else
  echo "⚠ swiftlint no instalado (brew install swiftlint)"; exit 1
fi
for p in "${pkgs[@]}"; do
  echo "▶ swift test $p"
  scripts/swift-test.sh "$p" --quiet 2>&1 | grep -vE "ld: warning: search path .*CommandLineTools/Developer/Library/Frameworks" || { echo "✗ $p"; exit 1; }
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "✗ $p"; exit 1; }
done
echo "✔ CI local verde"
