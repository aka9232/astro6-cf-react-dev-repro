#!/usr/bin/env bash
# Dev サーバーを起動 → index を要求 → Vite optimizer が react-dom/client を最適化したか判定 → kill
# 終了コード: 0=BUG再現(react-dom/client が未最適化) / 1=FIX(最適化済) / 2=判定不能
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="$(mktemp)"
CLIENT_JS="$(mktemp)"
HTML="$(mktemp)"

cleanup() {
  if [[ -n "${DEV_PID:-}" ]]; then
    kill "$DEV_PID" 2>/dev/null || true
    wait "$DEV_PID" 2>/dev/null || true
  fi
  pkill -f 'astro dev' 2>/dev/null || true
  rm -f "$LOG" "$CLIENT_JS" "$HTML"
}
trap cleanup EXIT

rm -rf .astro node_modules/.vite

pnpm astro dev >"$LOG" 2>&1 &
DEV_PID=$!
for _ in $(seq 1 120); do
  if grep -qE 'Local.+http' "$LOG"; then break; fi
  sleep 0.5
done
if ! grep -qE 'Local.+http' "$LOG"; then
  echo 'dev サーバーが起動しなかった' >&2
  tail -n 60 "$LOG" >&2
  exit 2
fi

curl -s -o "$HTML" http://127.0.0.1:4321/
RENDERER=$(grep -oE 'renderer-url="[^"]+"' "$HTML" | head -n1 | sed 's/renderer-url="\([^"]*\)"/\1/')
echo "renderer-url: $RENDERER"

sleep 4

if [[ -n "$RENDERER" ]]; then
  curl -s -o "$CLIENT_JS" "http://127.0.0.1:4321${RENDERER}"
  echo '--- renderer client.js first 3 imports ---'
  grep -E '^import ' "$CLIENT_JS" | head -n 5
  echo '-------------------------------------------'
fi

echo '--- _metadata.json optimized keys ---'
OPTIMIZED=$(python3 -c "import json,sys;
try:
  d=json.load(open('node_modules/.vite/deps/_metadata.json'));
  keys=sorted(d['optimized'].keys());
  [print(' ', k) for k in keys];
  print('__HAS_RDC__' if 'react-dom/client' in d['optimized'] else '__NO_RDC__');
  print('__HAS_RD__' if 'react-dom' in d['optimized'] else '__NO_RD__');
except Exception as e:
  print('ERR', e)
")
echo "$OPTIMIZED"

if echo "$OPTIMIZED" | grep -q '__HAS_RDC__'; then
  echo 'VERDICT: FIX (react-dom/client optimized)'
  exit 1
fi
echo 'VERDICT: BUG (react-dom/client NOT optimized — raw CJS served)'
exit 0
