#!/usr/bin/env bash
# Observed defect: fleet measured=624x350 (mode) while play-time claim is often
# 624x480. Product must pin OUTPUT I420 to 449280. crop=618:480 on 350 input
# fails ffmpeg (EINVAL) — that is the RED class. FOAR into coded 624 is GREEN.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/test_624x350_force_scale_out"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
FB=449280
N=3
WANT=$((FB * N))

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL no ffmpeg" >&2
  exit 1
fi

fail=0
# RED: legacy crop_pad claim path
set +e
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
  -an -vf "crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black" \
  -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/red.yuv" 2>"$OUT/red.err"
red_rc=$?
set -e
red_b=0
[[ -f "$OUT/red.yuv" ]] && red_b=$(wc -c <"$OUT/red.yuv" | tr -d ' ')
if [[ "$red_rc" -ne 0 || "$red_b" -ne "$WANT" ]]; then
  echo "PASS_RED crop_pad_on_350 rc=$red_rc bytes=$red_b (not product $WANT)"
else
  echo "FAIL_RED crop_pad accidentally produced product bytes" >&2
  fail=$((fail + 1))
fi
echo "red true rc=$red_rc"

# GREEN: product FOAR into coded 624
set +e
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
  -an -vf "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2" \
  -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/green.yuv" 2>"$OUT/green.err"
gr_rc=$?
set -e
gr_b=0
[[ -f "$OUT/green.yuv" ]] && gr_b=$(wc -c <"$OUT/green.yuv" | tr -d ' ')
if [[ "$gr_rc" -eq 0 && "$gr_b" -eq "$WANT" ]]; then
  echo "PASS_GREEN foar_coded_on_350 rc=0 bytes=$gr_b"
else
  echo "FAIL_GREEN foar_coded rc=$gr_rc bytes=$gr_b want=$WANT" >&2
  fail=$((fail + 1))
fi
echo "green true rc=$gr_rc"

# GREEN: same FOAR on true 624x480 still 449280 (no row destroy into 618)
set +e
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x480:rate=24" \
  -an -vf "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2" \
  -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/g480.yuv" 2>/dev/null
g480_rc=$?
set -e
g480_b=0
[[ -f "$OUT/g480.yuv" ]] && g480_b=$(wc -c <"$OUT/g480.yuv" | tr -d ' ')
if [[ "$g480_rc" -eq 0 && "$g480_b" -eq "$WANT" ]]; then
  echo "PASS_GREEN foar_coded_on_480 bytes=$g480_b"
else
  echo "FAIL_GREEN foar_on_480 rc=$g480_rc bytes=$g480_b" >&2
  fail=$((fail + 1))
fi
echo "g480 true rc=$g480_rc"

# Plan string pin via unit binary if present
if [[ -x "$ROOT/build/test_ffmpeg_vf" ]]; then
  "$ROOT/build/test_ffmpeg_vf" >/dev/null
  echo "unit_vf true rc=$?"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "TEST_624x350_FORCE_SCALE_OUT_FAIL fail=$fail"
  exit 1
fi
echo "TEST_624x350_FORCE_SCALE_OUT_OK"
exit 0
