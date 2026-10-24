#!/usr/bin/env bash
# Prueba de humo: arranca build/MiniMix.app (firmada con sandbox) unos segundos y comprueba
# que sigue viva en modo real (`live: ok`; con MINIMIX_REQUIRE_LIVE=1 no cae a la demo).
# Detecta fallos que `swift test` no ve (sandbox, recursos, arranque).
# Uso: scripts/smoke-app.sh [segundos]   (requiere scripts/bundle-app.sh antes; abre una ventana)
set -euo pipefail
cd "$(dirname "$0")/.."
secs="${1:-8}"
bin=build/MiniMix.app/Contents/MacOS/MiniMix
[[ -x "$bin" ]] || { echo "✗ falta $bin (ejecuta scripts/bundle-app.sh)"; exit 1; }
log="$(mktemp -t minimix-smoke)"
MINIMIX_REQUIRE_LIVE=1 "$bin" >"$log" 2>&1 &
pid=$!
sleep "$secs"
if kill -0 "$pid" 2>/dev/null && grep -q "^live: ok" "$log"; then
  rss=$(ps -o rss= -p "$pid" | tr -d ' ')
  kill "$pid"; wait "$pid" 2>/dev/null || true
  echo "✔ la app siguió viva ${secs} s (RSS $((rss / 1024)) MB)"
else
  kill "$pid" 2>/dev/null || true
  echo "✗ la app no arrancó en modo real o terminó antes de ${secs} s:"; tail -40 "$log"; exit 1
fi
