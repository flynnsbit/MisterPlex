#!/usr/bin/env bash
# P3-3l5 hybrid product gate (simulation only).
#
# Documented intent (docs/phase3-3l-idct.md §3.3l-5):
#   - Allow STREAM to skip host F1 when FPGA recon_ok
#   - Host fallback on CABAC / fail
# Honest MB boundary given P3-3l4 (intra green / inter red):
#   FPGA owns supported intra MBs; ARM/host owns inter/CABAC/unsupported.
#   Unmarked unsupported must never silently score as FPGA product.
#
# Pre-register (plex_inter_p16 320x240 12f = 1 I + 11 P, 300 MB/frame):
#   FPGA fraction = 300/3600 = 0.083333 (I frame only under default caps)
#   product_recon_ok = 0 on the multi-frame sequence (host MBs present)
# Falsify handoff if: unmarked inter claimed FPGA and scores green; dropped
# plane scores green; colorspace/loop-filter refusal is bypassed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/p3_hybrid_gate"
mkdir -p "$OUT"

SEQ="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json"
MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json"
GOLDEN="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_hybrid_mb_own.sv"
TOP="$ROOT/tests/rtl/h264_hybrid_mb_own_tb_top.sv"
TB="$ROOT/tests/rtl/h264_hybrid_mb_own_tb.cpp"
BUILD="$ROOT/build/verilator/h264_hybrid_mb_own"
BUILD_FAULT="$ROOT/build/verilator/h264_hybrid_mb_own_fault"

echo "P3-3l5 PRE-REGISTER: expect fpga_fraction=0.083333 (300/3600) product_recon_ok=0 on 12f ladder"

# --- product QIP + wiring membership ---
# Filenames are built without a bare "<mod>.sv" token so test_bench_rtl_filelists
# does not treat wiring greps as Verilator compile inputs (only $RTL is compiled).
if ! grep -q 'rtl/h264_hybrid_mb_own.sv' "$QIP"; then
  echo "FAIL hybrid gate: files.qip missing h264_hybrid_mb_own.sv" >&2
  exit 2
fi
python3 - <<'PY' "$ROOT"
import sys
from pathlib import Path
root = Path(sys.argv[1])
rtl = root / "fpga" / "Plex_MiSTer" / "rtl"
checks = [
    (rtl / ("decode_stub" + ".sv"), "h264_hybrid_mb_own"),
    (rtl / ("stream_path" + ".sv"), "product_recon_ok"),
    (rtl / ("h264_decode_top" + ".sv"), "hybrid_host_required"),
]
for path, needle in checks:
    text = path.read_text(errors="replace")
    if needle not in text:
        raise SystemExit(f"FAIL hybrid gate: {path.name} missing {needle}")
print("OK hybrid product wiring strings present")
PY

# --- RTL sim (ownership classifier + mutation twin) ---
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_hybrid_mb_own real RTL simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
    exit 3
  fi
else
  if [[ "$VERILATOR_RC" -ne 0 ]]; then
    echo "RTL SIM ERROR: Verilator probe failed" >&2
    printf '%s\n' "$VERILATOR_VERSION" >&2
    exit "$VERILATOR_RC"
  fi
  mkdir -p "$BUILD" "$BUILD_FAULT"
  echo "RTL SIM: using $VERILATOR_VERSION (h264_hybrid_mb_own)" >&2
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$BUILD" \
    --top-module h264_hybrid_mb_own_tb_top -Wno-fatal \
    -CFLAGS "-std=c++17 -O2" \
    "$TOP" "$RTL" "$TB"
  "$BUILD/Vh264_hybrid_mb_own_tb_top"

  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$BUILD_FAULT" \
    --top-module h264_hybrid_mb_own_tb_top -GFAULT_CLAIM_INTER=1 -Wno-fatal \
    -CFLAGS "-std=c++17 -O2" \
    "$TOP" "$RTL" "$TB"
  set +e
  FAULT_OUT="$("$BUILD_FAULT/Vh264_hybrid_mb_own_tb_top" 2>&1)"
  FAULT_RC=$?
  set -e
  if [[ "$FAULT_RC" -eq 0 ]]; then
    printf '%s\n' "$FAULT_OUT"
    echo "FAIL hybrid RTL mutation: FAULT_CLAIM_INTER unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'FAIL hybrid_own' <<<"$FAULT_OUT"
  echo "OK hybrid RTL mutation twin: unmarked/claimed inter ownership went red rc=$FAULT_RC"
fi

# --- Compose + score (honest hybrid product) ---
# FPGA planes = golden (stands in for proven intra path); host = golden.
# Default map: I→fpga, P→host. Composite must still match golden exactly.
KINDS="I,P,P,P,P,P,P,P,P,P,P,P"
OWN_MAP="$OUT/own_default.json"
COMPOSE="$OUT/hybrid_default.i420"
SUMMARY="$OUT/compose_default.json"
SCORE_JSON="$OUT/score_default.json"

python3 "$ROOT/tools/hybrid_compose_i420.py" \
  --fpga-planes "$GOLDEN" \
  --host-planes "$GOLDEN" \
  --width 320 --height 240 --frames 12 \
  --default-map-from-kinds "$KINDS" \
  --write-own-map "$OWN_MAP" \
  --output "$COMPOSE" \
  --summary "$SUMMARY"

python3 - "$SUMMARY" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
# Pre-register: 300/3600
if s["fpga_mb"] != 300 or s["host_mb"] != 3300 or s["total_mb"] != 3600:
    raise SystemExit(f"FAIL hybrid fraction: fpga={s['fpga_mb']} host={s['host_mb']} total={s['total_mb']}")
frac = s["fpga_fraction"]
if abs(frac - (300/3600)) > 1e-9:
    raise SystemExit(f"FAIL hybrid fraction value {frac}")
if s["product_recon_ok"]:
    raise SystemExit("FAIL product_recon_ok must be 0 when any host MB remains")
print(f"OK hybrid pre-register hit: fpga_fraction={frac:.6f} product_recon_ok=0")
PY

"$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$COMPOSE" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --output "$SCORE_JSON"
python3 - "$SCORE_JSON" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
if not s["summary"]["strict_pass"]:
    raise SystemExit("FAIL hybrid default compose did not strict_pass against golden")
if s["summary"]["intra"]["mb_exact"] != 300:
    raise SystemExit("FAIL hybrid intra score")
if s["summary"]["inter"]["mb_exact"] != 3300:
    raise SystemExit("FAIL hybrid inter host-backed score")
print("OK hybrid compose+score green under default ownership map")
PY

# --- Mutation twin 1: claim inter as FPGA but feed wrong FPGA pixels for P ---
# Build a defective "FPGA" plane (corrupt P-frame Y) and claim all P MBs FPGA-owned.
# If ownership were silent/unmarked, this could look plausible; gate must go red.
BAD_FPGA="$OUT/fpga_bad_p.i420"
python3 - "$GOLDEN" "$BAD_FPGA" <<'PY'
import sys
from pathlib import Path
src = bytearray(Path(sys.argv[1]).read_bytes())
fb = 320 * 240 * 3 // 2
# corrupt first P frame (frame 1) Y plane
for i in range(fb, fb + 320 * 240):
    src[i] ^= 0x5A
Path(sys.argv[2]).write_bytes(bytes(src))
PY

CLAIM_COMPOSE="$OUT/hybrid_claim_inter.i420"
CLAIM_SUMMARY="$OUT/compose_claim.json"
python3 "$ROOT/tools/hybrid_compose_i420.py" \
  --fpga-planes "$BAD_FPGA" \
  --host-planes "$GOLDEN" \
  --width 320 --height 240 --frames 12 \
  --default-map-from-kinds "$KINDS" \
  --claim-inter-as-fpga \
  --output "$CLAIM_COMPOSE" \
  --summary "$CLAIM_SUMMARY"

set +e
CLAIM_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$CLAIM_COMPOSE" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --expect-red 2>&1)"
CLAIM_RC=$?
set -e
if [[ "$CLAIM_RC" -ne 0 ]]; then
  printf '%s\n' "$CLAIM_OUT"
  echo "FAIL hybrid mutation claim-inter: expected-red score rc=$CLAIM_RC" >&2
  exit 1
fi
grep -q 'strict_pass=0' <<<"$CLAIM_OUT"
echo "OK hybrid mutation twin: unsupported/inter claimed as FPGA went RED"

# --- Mutation twin 2: drop U plane in composite ---
DROP_COMPOSE="$OUT/hybrid_drop_u.i420"
python3 "$ROOT/tools/hybrid_compose_i420.py" \
  --fpga-planes "$GOLDEN" \
  --host-planes "$GOLDEN" \
  --width 320 --height 240 --frames 12 \
  --default-map-from-kinds "$KINDS" \
  --drop-plane U --drop-frame 0 \
  --output "$DROP_COMPOSE" \
  --summary "$OUT/compose_drop.json"
set +e
DROP_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$DROP_COMPOSE" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --expect-red 2>&1)"
DROP_RC=$?
set -e
if [[ "$DROP_RC" -ne 0 ]]; then
  printf '%s\n' "$DROP_OUT"
  echo "FAIL hybrid mutation drop-plane: expected-red rc=$DROP_RC" >&2
  exit 1
fi
grep -q 'strict_pass=0' <<<"$DROP_OUT"
echo "OK hybrid mutation twin: dropped plane went RED"

# --- Mutation twin 3: refusal must not be bypassable via hybrid path ---
set +e
COLOR_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" --golden-manifest "$MANIFEST" --golden-planes "$GOLDEN" \
  --candidate-planes "$COMPOSE" --candidate-colorspace I420_FROM_RGB565 \
  --reference-h264-loop-filter disabled --candidate-h264-loop-filter disabled 2>&1)"
COLOR_RC=$?
set -e
if [[ "$COLOR_RC" -ne 9 ]]; then
  printf '%s\n' "$COLOR_OUT"
  echo "FAIL hybrid refusal twin: colorspace rc=$COLOR_RC want 9" >&2
  exit 1
fi
grep -q 'candidate colorspace' <<<"$COLOR_OUT"

set +e
LOOP_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" --golden-manifest "$MANIFEST" --golden-planes "$GOLDEN" \
  --candidate-planes "$COMPOSE" --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled --candidate-h264-loop-filter enabled 2>&1)"
LOOP_RC=$?
set -e
if [[ "$LOOP_RC" -ne 9 ]]; then
  printf '%s\n' "$LOOP_OUT"
  echo "FAIL hybrid refusal twin: loop-filter rc=$LOOP_RC want 9" >&2
  exit 1
fi
grep -q 'loop-filter mismatch' <<<"$LOOP_OUT"
echo "OK hybrid mutation twin: colorspace/loop-filter refusal preserved (rc=9)"

# --- Mutation twin 4: unmarked MB forced as FPGA with bad pixels ---
UNMARK_COMPOSE="$OUT/hybrid_unmark.i420"
python3 "$ROOT/tools/hybrid_compose_i420.py" \
  --fpga-planes "$BAD_FPGA" \
  --host-planes "$GOLDEN" \
  --width 320 --height 240 --frames 12 \
  --own-map "$OWN_MAP" \
  --force-unmarked-as-fpga \
  --output "$UNMARK_COMPOSE" \
  --summary "$OUT/compose_unmark.json"
set +e
UNMARK_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$UNMARK_COMPOSE" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --expect-red 2>&1)"
UNMARK_RC=$?
set -e
if [[ "$UNMARK_RC" -ne 0 ]]; then
  printf '%s\n' "$UNMARK_OUT"
  echo "FAIL hybrid mutation unmarked-as-fpga: expected-red rc=$UNMARK_RC" >&2
  exit 1
fi
echo "OK hybrid mutation twin: unmarked MB forced FPGA went RED"

echo "test_p3_hybrid_gate: OK RTL own + compose fraction 300/3600 + 4 mutation twins RED + refusal preserved"
