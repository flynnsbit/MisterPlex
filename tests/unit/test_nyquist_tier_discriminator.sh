#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/nyquist_tier"
mkdir -p "$OUT"
set +e
python3 "$ROOT/scripts/gen_nyquist_tier_discriminator.py" --out-dir "$OUT" --duration 4 >"$OUT/gen.log" 2>&1
g=$?
set -e
echo "gen true_rc=$g"
[[ "$g" -eq 0 ]] || { tail -20 "$OUT/gen.log"; exit 1; }
set +e
python3 "$ROOT/tools/verify_nyquist_tier_discriminator.py" \
  --p480 "$OUT/disc_nyquist_480p_624x480.mp4" \
  --p240 "$OUT/disc_nyquist_240p_320x240.mp4" \
  --json-out "$OUT/v.json" >"$OUT/v.log" 2>&1
v=$?
set -e
echo "verify true_rc=$v"
tail -5 "$OUT/v.log"
[[ "$v" -eq 0 ]] || exit 1
echo "NYQUIST_TIER_GATE_OK"
exit 0
