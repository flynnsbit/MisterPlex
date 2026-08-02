#!/usr/bin/env bash
# RED/GREEN host gate: product FORCE_SCALE vf pins OUTPUT I420 to 449280 bytes
# for every delivered geometry class parent listed (general 480p residual).
#
# Pre-register:
#   GREEN: for each source WxH, ffmpeg -vf product_scale_pad -frames:v N -f rawvideo
#          yields exactly N * 449280 bytes (coded 624x480 I420).
#   RED twin: same sources with -vf null / no pad emit != 449280 per frame.
#
# No device. Captures true rc directly (never through a pipe on the final status).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/force_scale_ffmpeg_out"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
CODED_W=624
CODED_H=480
DISP_W=618
DISP_H=480
# Product silicon paths (media_player + ffmpeg_vf.hpp):
#   non-bank-height / narrow: FOAR decrease into CODED bank (never display 618)
#   bank-height wide or exact-unverified: buildCropPadNoScale (no FOAR V-resample)
# Parent 2026-08-02: scale=618:480:FOAR was the measured row-destroyer on rk6.
PRODUCT_VF="scale=${CODED_W}:${CODED_H}:force_original_aspect_ratio=decrease,pad=${CODED_W}:${CODED_H}:(ow-iw)/2:(oh-ih)/2"
# Center-crop when source_w > coded (640/720); left crop when source_w == coded.
CROP_PAD_EXACT="crop=${DISP_W}:${DISP_H}:0:0,pad=${CODED_W}:${CODED_H}:0+(${DISP_W}-iw)/2:0+(${DISP_H}-ih)/2:color=black"
CROP_PAD_HFIT="crop=${DISP_W}:${DISP_H}:(iw-${DISP_W})/2:0,pad=${CODED_W}:${CODED_H}:0+(${DISP_W}-iw)/2:0+(${DISP_H}-ih)/2:color=black"
FRAME_BYTES=$((CODED_W * CODED_H * 3 / 2)) # 449280
NFRAMES=3
EXPECTED=$((FRAME_BYTES * NFRAMES))

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL ffmpeg not found" >&2
  exit 1
fi

pass=0
fail=0

run_case() {
  local label="$1" src_w="$2" src_h="$3" vf="$4" want_bytes="$5" want_rc_match="$6"
  local raw="$OUT/${label}.yuv"
  local err="$OUT/${label}.err"
  rm -f "$raw"
  # lavfi testsrc2 at exact geometry; -pix_fmt yuv420p even for odd inputs
  # (ffmpeg rounds chroma). Product path always converts to yuv420p on output.
  set +e
  "$FFMPEG" -hide_banner -loglevel error -nostdin \
    -f lavfi -i "testsrc2=size=${src_w}x${src_h}:rate=24" \
    -an -vf "$vf" -pix_fmt yuv420p -frames:v "$NFRAMES" \
    -f rawvideo -y "$raw" 2>"$err"
  local rc=$?
  set -e
  if [[ ! -f "$raw" ]]; then
    echo "FAIL $label: no output rc=$rc" >&2
    cat "$err" >&2 || true
    fail=$((fail + 1))
    return
  fi
  local bytes
  bytes=$(wc -c <"$raw" | tr -d ' ')
  if [[ "$want_rc_match" == "1" ]]; then
    if [[ "$rc" -eq 0 && "$bytes" -eq "$want_bytes" ]]; then
      echo "PASS $label src=${src_w}x${src_h} bytes=$bytes want=$want_bytes"
      pass=$((pass + 1))
    else
      echo "FAIL $label src=${src_w}x${src_h} rc=$rc bytes=$bytes want=$want_bytes" >&2
      cat "$err" >&2 || true
      fail=$((fail + 1))
    fi
  else
    # RED twin: must NOT match product contract
    if [[ "$bytes" -ne "$want_bytes" ]]; then
      echo "PASS_RED $label src=${src_w}x${src_h} bytes=$bytes != product $want_bytes"
      pass=$((pass + 1))
    else
      echo "FAIL_RED $label accidentally matched product bytes=$bytes" >&2
      fail=$((fail + 1))
    fi
  fi
}

echo "PRODUCT_VF=$PRODUCT_VF"
echo "CROP_PAD_EXACT=$CROP_PAD_EXACT"
echo "CROP_PAD_HFIT=$CROP_PAD_HFIT"
echo "FRAME_BYTES=$FRAME_BYTES NFRAMES=$NFRAMES EXPECTED=$EXPECTED"

# GREEN: FORCE_SCALE scale+pad pins OUTPUT bytes (non-bank-height / general)
run_case "g_exact_bank_scale" 624 480 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_scope_235" 624 352 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_624x350" 624 350 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_640x480_scale" 640 480 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_720x480_scale" 720 480 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_704x396" 704 396 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_1440x1080" 1440 1080 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_320x240" 320 240 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_426x240" 426 240 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_odd" 625 481 "$PRODUCT_VF" "$EXPECTED" 1
run_case "g_618x480" 618 480 "$PRODUCT_VF" "$EXPECTED" 1

# GREEN: product bank-height path is crop+pad (WIDTH≠624 and exact-unverified)
# — still pins 449280, and is the FOAR-free path tip ships.
run_case "g_exact_crop_pad" 624 480 "$CROP_PAD_EXACT" "$EXPECTED" 1
run_case "g_640_crop_pad" 640 480 "$CROP_PAD_HFIT" "$EXPECTED" 1
run_case "g_720_crop_pad" 720 480 "$CROP_PAD_HFIT" "$EXPECTED" 1

# RED twin: no scale/pad — source size leaks to pipe (except exact bank)
run_case "r_640_identity" 640 480 "null" "$EXPECTED" 0
run_case "r_352_identity" 624 352 "null" "$EXPECTED" 0
run_case "r_720_identity" 720 480 "null" "$EXPECTED" 0
run_case "r_426_identity" 426 240 "null" "$EXPECTED" 0

echo "SUMMARY pass=$pass fail=$fail frame_bytes=$FRAME_BYTES"
if [[ "$fail" -ne 0 ]]; then
  echo "FORCE_SCALE_FFMPEG_OUT_FAIL fail=$fail"
  exit 1
fi
if [[ "$pass" -lt 18 ]]; then
  echo "FORCE_SCALE_FFMPEG_OUT_FAIL pass=$pass too few"
  exit 1
fi
echo "FORCE_SCALE_FFMPEG_OUT_OK pass=$pass"
exit 0
