#!/usr/bin/env bash
# Host self-verify of A/V glass-sync fixture (offset 0 and +100). No device.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/avsync_glass_fixture"
mkdir -p "$OUT"
GEN="$ROOT/scripts/gen_avsync_glass_sync.py"
VER="$ROOT/tools/verify_avsync_glass_fixture.py"
DUR="${AVSYNC_GLASS_TEST_DURATION:-12}"

set +e
python3 "$GEN" --out "$OUT/sync0.mp4" --duration "$DUR" --also-plus100 >"$OUT/gen.log" 2>&1
grc=$?
set -e
echo "gen true_rc=$grc"
if [[ "$grc" -ne 0 ]]; then tail -20 "$OUT/gen.log"; exit 1; fi

set +e
python3 "$VER" --mp4 "$OUT/sync0.mp4" --expect-offset-ms 0 --tol-ms 5 \
  --json-out "$OUT/v0.json" >"$OUT/v0.log" 2>&1
v0=$?
set -e
echo "verify0 true_rc=$v0"
tail -3 "$OUT/v0.log"
if [[ "$v0" -ne 0 ]]; then exit 1; fi

set +e
python3 "$VER" --mp4 "$OUT/sync0_audioPlus100ms.mp4" --expect-offset-ms 100 --tol-ms 5 \
  --json-out "$OUT/v100.json" >"$OUT/v100.log" 2>&1
v1=$?
set -e
echo "verify100 true_rc=$v1"
tail -3 "$OUT/v100.log"
if [[ "$v1" -ne 0 ]]; then exit 1; fi

echo "AVSYNC_GLASS_FIXTURE_GATE_OK"
exit 0
