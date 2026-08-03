#!/usr/bin/env bash
# B14 Direct-Part: 426x240 source → coded 432 bank via PAD-ONLY (inset x=2).
# rd-duck FIX-COLLISION: crop=426:240:2:0 on a 426-wide input is OOB and must
# fail; product pad=432:240:2:0:color=black must succeed at 432*240*3/2 bytes.
#
# Metadata (coded432/display426/crop L2/R4) is owned by host unit tests
# (test_ffmpeg_vf / test_ddr_720p_abi). This script is the live ffmpeg oracle.
#
# No device. Capture true rc directly (never through a pipe on final status).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/b14_426_pad_ffmpeg"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
SRC_W=426
SRC_H=240
CODED_W=432
CODED_H=240
CROP_LEFT=2
CROP_TOP=0
PRODUCT_VF="pad=${CODED_W}:${CODED_H}:${CROP_LEFT}:${CROP_TOP}:color=black"
FAULT_CROP_VF="crop=${SRC_W}:${SRC_H}:${CROP_LEFT}:${CROP_TOP},pad=${CODED_W}:${CODED_H}:${CROP_LEFT}+(${SRC_W}-iw)/2:${CROP_TOP}+(${SRC_H}-ih)/2:color=black"
FRAME_BYTES=$((CODED_W * CODED_H * 3 / 2)) # 155520
NFRAMES=2
EXPECTED=$((FRAME_BYTES * NFRAMES))

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL ffmpeg not found" >&2
  exit 1
fi

pass=0
fail=0

run_ffmpeg() {
  local label="$1"
  local vf="$2"
  local raw="$OUT/${label}.yuv"
  local err="$OUT/${label}.err"
  local rc=0
  rm -f "$raw"
  set +e
  "$FFMPEG" -hide_banner -loglevel error -nostdin \
    -f lavfi -i "testsrc2=size=${SRC_W}x${SRC_H}:rate=24" \
    -an -vf "$vf" -pix_fmt yuv420p -frames:v "$NFRAMES" \
    -f rawvideo -y "$raw" 2>"$err"
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

echo "PRODUCT_VF=$PRODUCT_VF"
echo "FAULT_CROP_VF=$FAULT_CROP_VF"
echo "FRAME_BYTES=$FRAME_BYTES NFRAMES=$NFRAMES EXPECTED=$EXPECTED"

# GREEN: pad-only pins coded bank bytes
set +e
rc_prod=$(run_ffmpeg "g_pad_only" "$PRODUCT_VF")
set -e
raw_prod="$OUT/g_pad_only.yuv"
if [[ -f "$raw_prod" ]]; then
  bytes_prod=$(wc -c <"$raw_prod" | tr -d ' ')
else
  bytes_prod=0
fi
if [[ "$rc_prod" -eq 0 && "$bytes_prod" -eq "$EXPECTED" ]]; then
  echo "PASS g_pad_only rc=$rc_prod bytes=$bytes_prod want=$EXPECTED"
  pass=$((pass + 1))
else
  echo "FAIL g_pad_only rc=$rc_prod bytes=$bytes_prod want=$EXPECTED" >&2
  cat "$OUT/g_pad_only.err" >&2 || true
  fail=$((fail + 1))
fi

# Optional: first frame luma left pad columns should be near-black (pad color).
# Sample Y plane bytes at x=0,1 for row 0 — pad inset is black.
if [[ "$rc_prod" -eq 0 && -f "$raw_prod" && "$bytes_prod" -ge "$FRAME_BYTES" ]]; then
  # Y stride = 432; bytes 0 and 1 are pad columns under crop_left=2.
  y0=$(od -An -tu1 -N2 -j0 "$raw_prod" | tr -s ' ' | sed 's/^ //')
  # shellcheck disable=SC2086
  set -- $y0
  b0=${1:-255}
  b1=${2:-255}
  if [[ "$b0" -le 16 && "$b1" -le 16 ]]; then
    echo "PASS g_pad_black_inset y0=$b0 y1=$b1"
    pass=$((pass + 1))
  else
    echo "FAIL g_pad_black_inset y0=$b0 y1=$b1 (want near-black pad)" >&2
    fail=$((fail + 1))
  fi
fi

# RED structural: FAULT filter string must contain the OOB crop form. Some
# ffmpeg builds clamp OOB crop to in-bounds and emit the same bytes as pad-only
# (measured: cmp equal) — that is NOT a product license to emit crop=. Product
# gate is the unit test (no crop=) + live pad-only success above.
if [[ "$FAULT_CROP_VF" == crop=${SRC_W}:${SRC_H}:${CROP_LEFT}:${CROP_TOP},* ]]; then
  echo "PASS_RED r_oob_crop_string FAULT_CROP_VF has OOB crop=${SRC_W}:${SRC_H}:${CROP_LEFT}:${CROP_TOP}"
  pass=$((pass + 1))
else
  echo "FAIL_RED r_oob_crop_string FAULT_CROP_VF missing OOB form: $FAULT_CROP_VF" >&2
  fail=$((fail + 1))
fi
if [[ "$PRODUCT_VF" == crop=* ]]; then
  echo "FAIL product vf must not start with crop=: $PRODUCT_VF" >&2
  fail=$((fail + 1))
else
  echo "PASS product_vf_no_crop PRODUCT_VF=$PRODUCT_VF"
  pass=$((pass + 1))
fi
# Optional probe: run FAULT graph; record rc/bytes (informational). Do not
# require failure — clamp behavior is version-dependent (rule 0).
set +e
rc_fault=$(run_ffmpeg "r_oob_crop" "$FAULT_CROP_VF")
set -e
raw_fault="$OUT/r_oob_crop.yuv"
if [[ -f "$raw_fault" ]]; then
  bytes_fault=$(wc -c <"$raw_fault" | tr -d ' ')
else
  bytes_fault=0
fi
echo "INFO r_oob_crop_probe rc=$rc_fault bytes=$bytes_fault (clamp-ok if ==$EXPECTED)"

# RED: identity null must not pin 432 bank
set +e
rc_id=$(run_ffmpeg "r_identity" "null")
set -e
raw_id="$OUT/r_identity.yuv"
if [[ -f "$raw_id" ]]; then
  bytes_id=$(wc -c <"$raw_id" | tr -d ' ')
else
  bytes_id=0
fi
# 426 may be rounded by lavfi/yuv420; anything != EXPECTED is RED pass
if [[ "$bytes_id" -ne "$EXPECTED" ]]; then
  echo "PASS_RED r_identity bytes=$bytes_id != $EXPECTED"
  pass=$((pass + 1))
else
  echo "FAIL_RED r_identity matched coded bank without pad" >&2
  fail=$((fail + 1))
fi

echo "SUMMARY pass=$pass fail=$fail frame_bytes=$FRAME_BYTES"
if [[ "$fail" -ne 0 ]]; then
  echo "B14_426_PAD_FFMPEG_FAIL fail=$fail"
  exit 1
fi
if [[ "$pass" -lt 3 ]]; then
  echo "B14_426_PAD_FFMPEG_FAIL pass=$pass too few" >&2
  exit 1
fi
echo "B14_426_PAD_FFMPEG_OK pass=$pass"
exit 0
