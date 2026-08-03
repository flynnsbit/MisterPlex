#!/usr/bin/env bash
# Host gate: audio frame-ID checksum + AAC survival + short fixture. No device.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/audio_frame_id"
mkdir -p "$OUT"

set +e
python3 "$ROOT/tools/verify_audio_frame_id.py" --duration 16 \
  --json-out "$OUT/synth.json" >"$OUT/synth.log" 2>&1
rc=$?
set -e
echo "synth_verify true_rc=$rc"
if [[ "$rc" -ne 0 ]]; then tail -30 "$OUT/synth.log"; exit 1; fi

set +e
python3 "$ROOT/scripts/gen_avsync_audio_id_fixture.py" \
  --out "$OUT/short.mp4" --duration 12 >"$OUT/gen.log" 2>&1
grc=$?
set -e
echo "gen true_rc=$grc"
if [[ "$grc" -ne 0 ]]; then tail -20 "$OUT/gen.log"; exit 1; fi

set +e
python3 "$ROOT/tools/verify_audio_frame_id.py" --duration 8 \
  --mp4 "$OUT/short.mp4" --json-out "$OUT/mp4.json" >"$OUT/mp4.log" 2>&1
mrc=$?
set -e
echo "mp4_verify true_rc=$mrc"
tail -8 "$OUT/mp4.log"
if [[ "$mrc" -ne 0 ]]; then exit 1; fi

echo "AUDIO_FRAME_ID_GATE_OK"
exit 0
