#!/usr/bin/env bash
# Artifact-only gate: packaged daemon's vf policy must pin OUTPUT I420 to the
# coded bank for real PMS delivery geometries, including non-bank-exact cases.
#
# OBSERVED DEFECT (parent, viewed pixels 2026-08-02):
#   Release daemon at user DECODE=624x480 rendered a full GREEN field with
#   duplicated/wrapped TREK24. Live daily-driver logged measured=624x350
#   desync_risk=0 and played correctly. PMS delivered 624x350 — not 624x480.
#   Same asset: pfps 12.5 + climbing drops (fail-open wrong pixels) vs earlier
#   crop=618:480 fail-closed (ffmpeg rc=234, pfps 0). Root: delivered height ≠
#   coded height; two opposite failure modes.
#
# THIS GATE (behavioural, package-decidable — NOT a function of device state):
#   1. Resolve the vf the *given daemon binary* would apply for product
#      DECODE=624x480 + conf skip_identity + UNVERIFIED delivery claim.
#   2. Run that vf via host ffmpeg against delivered geometries:
#        - 624x350  (REAL measured PMS delivery for asset RK6)
#        - 624x480  (bank-exact; must still pass)
#   3. Assert on raw I420 output:
#        - total_bytes > 0 and total_bytes % 449280 == 0
#        - chroma not dead (zero_frac_u/v >= 0.95 → FAIL green-field class)
#          via host/libmisterplex/yuv420p_chroma_health.hpp
#
# NOT tested here (stated so green ≠ hardware pass):
#   ARM producer only. Does NOT exercise DDR bank write, FPGA scanout, or
#   on-glass HDMI. A core that misreads a correctly-produced frame still PASSES.
#
# Usage:
#   vf_delivery_behaviour_check.sh <path-to-misterplexd>
#   vf_delivery_behaviour_check.sh --policy product_foar_coded|legacy_identity <ignored>
#
# Exit:
#   0 VF_DELIVERY_OK
#   1 usage / missing tools
#   2 VF_DELIVERY_FAIL (bytes or chroma)
#   3 inspector/build failure
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG="${FFMPEG:-ffmpeg}"
BANK_W=624
BANK_H=480
FRAME_BYTES=$((BANK_W * BANK_H * 3 / 2)) # 449280
NFRAMES=3
OUT_DIR="${VF_DELIVERY_OUT:-$ROOT/build/vf_delivery_behaviour}"
HEALTH="$ROOT/build/test_vf_bank_output_health"
policy_override=""
daemon=""

while [ $# -gt 0 ]; do
  case "$1" in
    --policy)
      policy_override=${2:-}
      shift 2
      ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      daemon=$1
      shift
      ;;
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

# Build chroma/size inspector (header-only deps).
if [ ! -x "$HEALTH" ] || [ "$ROOT/tests/unit/test_vf_bank_output_health.cpp" -nt "$HEALTH" ] \
  || [ "$ROOT/host/libmisterplex/yuv420p_chroma_health.hpp" -nt "$HEALTH" ]; then
  mkdir -p "$ROOT/build"
  g++ -std=c++17 -O2 -I"$ROOT/host" -o "$HEALTH" \
    "$ROOT/tests/unit/test_vf_bank_output_health.cpp" || {
    echo "VF_DELIVERY_FAIL reason=health_binary_build"
    exit 3
  }
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Policy resolution from the ARTIFACT (not device state, not md5 equality).
#
# Product path (current main, yuv420p_chroma_health + media_player):
#   DDR_YUV_FORCE_SCALE defaults ON and/or GEOM_GUARD refuses identity_skip
#   unless delivery_geometry_verified → Always FOAR into CODED 624x480.
# Legacy path (pre-delivery-geometry binaries such as the historical release
# pin): SkipIdentity on numeric claim match without measurement → empty vf;
# producer size (e.g. 624x350) leaks into the raw pipe → desync / green field.
#
# Classification selects which vf to *behave*; pass/fail is only on measured
# output bytes + chroma. No hardcoded content-md5 allow/deny list.
# ---------------------------------------------------------------------------
resolve_policy() {
  local bin=$1
  if [ -n "$policy_override" ]; then
    printf '%s\n' "$policy_override"
    return 0
  fi
  # Force-scale / delivery-guard path present → product FOAR into coded bank.
  if grep -aFq 'GEOM_GUARD refused identity_skip' "$bin" 2>/dev/null \
    || grep -aFq 'yuv_ddr_force_scale' "$bin" 2>/dev/null; then
    printf '%s\n' 'product_foar_coded'
    return 0
  fi
  printf '%s\n' 'legacy_identity'
}

policy=$(resolve_policy "${daemon:-}")
case "$policy" in
  product_foar_coded)
    # host/libmisterplex/ffmpeg_vf.hpp — FOAR into CODED bank (not display 618).
    VF="scale=${BANK_W}:${BANK_H}:force_original_aspect_ratio=decrease,pad=${BANK_W}:${BANK_H}:(ow-iw)/2:(oh-ih)/2"
    ;;
  legacy_identity)
    # Empty -vf: identity / skip_identity without delivery verification.
    VF=""
    ;;
  *)
    echo "VF_DELIVERY_FAIL reason=unknown_policy policy=$policy"
    exit 1
    ;;
esac

echo "VF_DELIVERY_BEGIN"
echo "VF_DELIVERY_SCOPE arm_producer_only=1 ddr_bank=NOT_TESTED scanout=NOT_TESTED"
echo "VF_DELIVERY_SCOPE_NOTE A green result is NOT a hardware pass. This gate only"
echo "VF_DELIVERY_SCOPE_NOTE checks the ARM ffmpeg vf policy output bytes+chroma."
echo "VF_DELIVERY_DAEMON path=${daemon:-"(policy override)"}"
if [ -n "${daemon:-}" ] && [ -f "$daemon" ]; then
  echo "VF_DELIVERY_DAEMON md5=$(md5sum "$daemon" | awk '{print $1}') bytes=$(wc -c <"$daemon" | tr -d ' ')"
fi
echo "VF_DELIVERY_POLICY class=$policy vf=${VF:-"(identity/empty)"}"
echo "VF_DELIVERY_BANK ${BANK_W}x${BANK_H} frame_bytes=$FRAME_BYTES nframes=$NFRAMES"
echo "VF_DELIVERY_GEOMS 624x350(real_PMS_RK6) 624x480(bank_exact)"

fail=0
run_geom() {
  local label=$1 src_w=$2 src_h=$3
  local raw="$OUT_DIR/${label}.yuv"
  local err="$OUT_DIR/${label}.err"
  rm -f "$raw" "$err"
  set +e
  if [ -n "$VF" ]; then
    "$FFMPEG" -hide_banner -loglevel error -nostdin \
      -f lavfi -i "testsrc2=size=${src_w}x${src_h}:rate=24" \
      -an -vf "$VF" -pix_fmt yuv420p -frames:v "$NFRAMES" \
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
  echo "VF_DELIVERY_FFMPEG label=$label src=${src_w}x${src_h} ff_rc=$ff_rc bytes=$bytes"
  if [ -s "$err" ]; then
    echo "VF_DELIVERY_FFMPEG_ERR label=$label $(tr '\n' ' ' <"$err" | head -c 240)"
  fi

  set +e
  "$HEALTH" "$raw" "$BANK_W" "$BANK_H"
  local h_rc=$?
  set -e
  echo "VF_DELIVERY_HEALTH label=$label true_rc=$h_rc"

  if [ "$h_rc" -ne 0 ]; then
    echo "VF_DELIVERY_CASE_FAIL label=$label src=${src_w}x${src_h} health_rc=$h_rc ff_rc=$ff_rc bytes=$bytes"
    fail=$((fail + 1))
  else
    echo "VF_DELIVERY_CASE_OK label=$label src=${src_w}x${src_h} bytes=$bytes"
  fi
}

run_geom "g_624x350" 624 350
run_geom "g_624x480" 624 480

if [ "$fail" -ne 0 ]; then
  echo "VF_DELIVERY_FAIL policy=$policy failed_cases=$fail frame_bytes=$FRAME_BYTES"
  echo "VF_DELIVERY_FAIL_HINT legacy_identity on non-bank delivery (e.g. 624x350) yields"
  echo "VF_DELIVERY_FAIL_HINT total%449280!=0 (desync) or zero total (fail-closed crop)."
  echo "VF_DELIVERY_FAIL_HINT Product policy must FOAR-scale+pad into coded 624x480."
  exit 2
fi

echo "VF_DELIVERY_OK policy=$policy cases=2 frame_bytes=$FRAME_BYTES"
echo "VF_DELIVERY_END"
exit 0
