#!/usr/bin/env bash
# Uso: scripts/swift-test.sh <ruta-paquete> [args extra de swift test]
# Ejecuta `swift test` con -warnings-as-errors. Con solo Command Line Tools
# (sin Xcode) añade la ruta del plugin de macros de Swift Testing.
set -euo pipefail
pkg="${1:?ruta del paquete}"; shift || true
extra=(-Xswiftc -warnings-as-errors)
source "$(dirname "$0")/env.sh"
if [[ "$dev_dir" == *CommandLineTools* ]]; then
  extra+=(-Xswiftc -plugin-path -Xswiftc "$dev_dir/usr/lib/swift/host/plugins/testing")
fi
exec swift test --package-path "$pkg" "${extra[@]}" "$@"
