#!/usr/bin/env bash
# Artifact-only POSITIVE capability gate: product vf policy must pin OUTPUT I420
# to the coded bank for arbitrary real-world delivered geometries — not only a
# bank-exact fixture (rd-review B6 residual).
#
# OBSERVED DEFECT (parent, viewed pixels 2026-08-02):
#   Release identity_skip on 624x350 → fail-OPEN green+wrap (pfps>0).
#   crop=618:480 on 350 → fail-CLOSED ffmpeg rc=234, 0 bytes, black.
#   240p always rescales into bank (desync impossible by construction).
#   480p identity_skip emits PMS delivery into 449280-byte reader.
#
# THIS GATE (behavioural — NOT device state, NOT md5 allow/deny):
#   1. Resolve policy from the daemon artifact (GEOM_GUARD / force_scale → product;
#      else legacy identity).
#   2. For each delivered geometry, drive the daemon's planner
#      (buildFfmpegVideoFilter via test_vf_plan_emit) under product Always +
#      unverified source, OR empty vf under legacy_identity.
#   3. Run host ffmpeg; assert on packed I420:
#        total > 0 && total % kPlex480pYuv420pBytes == 0
#        chroma not dead (all-0 green) and not flat-neutral (all-128 grey)
#
# Matrix (must not be narrowed to make green):
#   624x350  real measured PMS RK6 delivery
#   624x352  coded MB-aligned 22*16 with crop residual class
#   640x480  common ladder / hfit
#   720x480  DVD-class
#   1280x720 half-HD ceiling tier
#   624x480  bank-exact control
#
# NOT tested: DDR bank write, FPGA scanout, HDMI glass.
#
# Usage:
#   vf_delivery_behaviour_check.sh <path-to-misterplexd>
#   vf_delivery_behaviour_check.sh --policy product_foar_coded|legacy_identity [ignored]
# Exit: 0 OK, 1 usage, 2 FAIL, 3 build/tool
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG="${FFMPEG:-ffmpeg}"

_VF_LAYOUT_HPP="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"
_vf_layout_int() {
  local v
  v="$(grep -oE "${1}(\{|[[:space:]]*=[[:space:]]*)[0-9]+" "$_VF_LAYOUT_HPP" \
       | head -n1 | grep -oE '[0-9]+$')"
  [ -n "$v" ] || { echo "vf_delivery_behaviour_check: missing $1 in $_VF_LAYOUT_HPP" >&2; exit 3; }
  printf '%d' "$v"
}
BANK_W=$(_vf_layout_int kPlex480pCodedWidth)
BANK_H=$(_vf_layout_int kPlex480pCodedHeight)
FRAME_BYTES=$(_vf_layout_int kPlex480pYuv420pBytes)
NFRAMES=3
OUT_DIR="${VF_DELIVERY_OUT:-$ROOT/build/vf_delivery_behaviour}"
HEALTH="$ROOT/build/test_vf_bank_output_health"
PLAN_EMIT="$ROOT/build/test_vf_plan_emit"
policy_override=""
daemon=""

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) policy_override=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) daemon=$1; shift ;;
  esac
done

if [ -z "$policy_override" ] && { [ -z "$daemon" ] || [ ! -f "$daemon" ]; }; then
  echo "VF_DELIVERY_FAIL reason=usage need <misterplexd> or --policy ..."
  exit 1
fi
if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "VF_DELIVERY_FAIL reason=no_ffmpeg"
  exit 1
fi

mkdir -p "$ROOT/build" "$OUT_DIR"

build_tool() {
  local out=$1 src=$2
  if [ ! -x "$out" ] || [ "$src" -nt "$out" ] \
    || [ "$ROOT/host/libmisterplex/ffmpeg_vf.hpp" -nt "$out" ] \
    || [ "$ROOT/host/libmisterplex/ddr_frame_layout.hpp" -nt "$out" ] \
    || [ "$ROOT/host/libmisterplex/yuv420p_chroma_health.hpp" -nt "$out" ]; then
    g++ -std=c++17 -O2 -I"$ROOT/host" -o "$out" "$src" || return 1
  fi
  return 0
}
build_tool "$HEALTH" "$ROOT/tests/unit/test_vf_bank_output_health.cpp" || {
  echo "VF_DELIVERY_FAIL reason=health_binary_build"; exit 3; }
build_tool "$PLAN_EMIT" "$ROOT/tests/unit/test_vf_plan_emit.cpp" || {
  echo "VF_DELIVERY_FAIL reason=plan_emit_build"; exit 3; }

resolve_policy() {
  local bin=$1
  if [ -n "$policy_override" ]; then
    printf '%s\n' "$policy_override"
    return 0
  fi
  if grep -aFq 'GEOM_GUARD refused identity_skip' "$bin" 2>/dev/null \
    || grep -aFq 'yuv_ddr_force_scale' "$bin" 2>/dev/null \
    || grep -aFq 'force_unverified_claim_scale_pad_coded' "$bin" 2>/dev/null; then
    printf '%s\n' 'product_foar_coded'
    return 0
  fi
  printf '%s\n' 'legacy_identity'
}

policy=$(resolve_policy "${daemon:-}")

echo "VF_DELIVERY_BEGIN"
echo "VF_DELIVERY_SCOPE arm_producer_only=1 ddr_bank=NOT_TESTED scanout=NOT_TESTED"
echo "VF_DELIVERY_SCOPE_NOTE A green result is NOT a hardware pass. This gate only"
echo "VF_DELIVERY_SCOPE_NOTE checks the ARM ffmpeg vf policy output bytes+chroma."
echo "VF_DELIVERY_DAEMON path=${daemon:-"(policy override)"}"
if [ -n "${daemon:-}" ] && [ -f "$daemon" ]; then
  echo "VF_DELIVERY_DAEMON md5=$(md5sum "$daemon" | awk '{print $1}') bytes=$(wc -c <"$daemon" | tr -d ' ')"
fi
echo "VF_DELIVERY_POLICY class=$policy"
echo "VF_DELIVERY_BANK ${BANK_W}x${BANK_H} frame_bytes=$FRAME_BYTES nframes=$NFRAMES"
echo "VF_DELIVERY_GEOMS 624x350(real_PMS_RK6) 624x352 640x480 720x480 1280x720 624x480(bank_exact)"

fail=0
applied=0
cases=0

run_geom() {
  local label=$1 src_w=$2 src_h=$3
  local raw="$OUT_DIR/${label}.yuv"
  local err="$OUT_DIR/${label}.err"
  local plan_line vf reason identity scale_applied
  rm -f "$raw" "$err"
  cases=$((cases + 1))

  if [ "$policy" = "legacy_identity" ]; then
    reason="legacy_identity"
    identity=1
    scale_applied=0
    vf=""
  else
    # Product path: FORCE_SCALE Always + unverified delivery claim at measured src.
    plan_line=$("$PLAN_EMIT" "$src_w" "$src_h" --verified 0 --mode always)
    reason=$(printf '%s' "$plan_line" | sed -n 's/.*reason=\([^ ]*\).*/\1/p')
    identity=$(printf '%s' "$plan_line" | sed -n 's/.*identity_skip=\([01]\).*/\1/p')
    scale_applied=$(printf '%s' "$plan_line" | sed -n 's/.*scale_applied=\([01]\).*/\1/p')
    vf=$(printf '%s' "$plan_line" | sed -n 's/.*vf=//p')
    if [ "$vf" = "(none)" ]; then vf=""; fi
    echo "VF_DELIVERY_PLAN label=$label $plan_line"
    # Positive capability: product must not identity_skip on unverified non-exact
    # or unverified exact claims.
    if [ "${identity:-1}" -eq 1 ]; then
      echo "VF_DELIVERY_CASE_FAIL label=$label reason=product_identity_skip_unverified plan=$reason"
      fail=$((fail + 1))
      applied=$((applied + 1))
      return 0
    fi
  fi

  set +e
  if [ -n "$vf" ]; then
    "$FFMPEG" -hide_banner -loglevel error -nostdin \
      -f lavfi -i "testsrc2=size=${src_w}x${src_h}:rate=24" \
      -an -vf "$vf" -pix_fmt yuv420p -frames:v "$NFRAMES" \
      -f rawvideo -y "$raw" 2>"$err"
  else
    "$FFMPEG" -hide_banner -loglevel error -nostdin \
      -f lavfi -i "testsrc2=size=${src_w}x${src_h}:rate=24" \
      -an -pix_fmt yuv420p -frames:v "$NFRAMES" \
      -f rawvideo -y "$raw" 2>"$err"
  fi
  local ff_rc=$?
  set -e
  local bytes=0
  if [ -f "$raw" ]; then
    bytes=$(wc -c <"$raw" | tr -d ' ')
  fi
  echo "VF_DELIVERY_FFMPEG label=$label src=${src_w}x${src_h} ff_rc=$ff_rc bytes=$bytes vf=${vf:-"(identity/empty)"}"

  # Whole-bank: total > 0 && total % FRAME_BYTES == 0 (also checked inside HEALTH)
  if [ "$bytes" -le 0 ]; then
    echo "VF_DELIVERY_CASE_FAIL label=$label src=${src_w}x${src_h} reason=zero_total fail_CLOSED ff_rc=$ff_rc"
    fail=$((fail + 1)); applied=$((applied + 1)); return 0
  fi
  if [ $((bytes % FRAME_BYTES)) -ne 0 ]; then
    echo "VF_DELIVERY_CASE_FAIL label=$label src=${src_w}x${src_h} reason=not_multiple_of_bank bytes=$bytes frame_bytes=$FRAME_BYTES remainder=$((bytes % FRAME_BYTES)) fail_OPEN"
    fail=$((fail + 1)); applied=$((applied + 1)); return 0
  fi

  set +e
  "$HEALTH" "$raw" "$BANK_W" "$BANK_H"
  local h_rc=$?
  set -e
  echo "VF_DELIVERY_HEALTH label=$label true_rc=$h_rc"

  if [ "$h_rc" -ne 0 ]; then
    echo "VF_DELIVERY_CASE_FAIL label=$label src=${src_w}x${src_h} health_rc=$h_rc ff_rc=$ff_rc bytes=$bytes"
    fail=$((fail + 1)); applied=$((applied + 1))
  else
    echo "VF_DELIVERY_CASE_OK label=$label src=${src_w}x${src_h} bytes=$bytes reason=$reason"
    applied=$((applied + 1))
  fi
}

# Full matrix — do not narrow to make green.
run_geom "g_624x350" 624 350
run_geom "g_624x352" 624 352
run_geom "g_640x480" 640 480
run_geom "g_720x480" 720 480
run_geom "g_1280x720" 1280 720
run_geom "g_624x480" 624 480

echo "VF_DELIVERY_APPLIED cases=$cases applied=$applied fail=$fail frame_bytes=$FRAME_BYTES"

if [ "$fail" -ne 0 ]; then
  echo "VF_DELIVERY_FAIL policy=$policy failed_cases=$fail frame_bytes=$FRAME_BYTES"
  echo "VF_DELIVERY_FAIL_HINT legacy_identity on non-bank delivery yields"
  echo "VF_DELIVERY_FAIL_HINT total%${FRAME_BYTES}!=0 (desync) or zero total (fail-closed crop)."
  echo "VF_DELIVERY_FAIL_HINT Product policy must FOAR/crop+pad into coded ${BANK_W}x${BANK_H}."
  exit 2
fi

if [ "$cases" -lt 6 ]; then
  echo "VF_DELIVERY_FAIL reason=matrix_narrowed cases=$cases want>=6"
  exit 2
fi

echo "VF_DELIVERY_OK policy=$policy cases=$cases frame_bytes=$FRAME_BYTES applied=$applied"
echo "VF_DELIVERY_END"
exit 0
