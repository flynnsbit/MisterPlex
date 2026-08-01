#!/usr/bin/env bash
# test_avsync_measure_hdmi.sh — RED/GREEN proofs for tools/avsync_measure_hdmi.py
#
# Host-only. Does NOT touch /dev/video0, ALSA, SSH, or the MiSTer.
# Builds synthetic A/V files from assets/avsync/sync_24fps_blip.mp4 with known
# injected offsets and checks recovery + return codes.
#
# Contract:
#   aligned (0 ms)           → rc=0, |median| <= 15 ms
#   +250 ms audio delay      → rc=2 (tol=42), median ≈ +250 ms
#   -200 ms (itsoffset)      → rc=2, median ≈ -200 ms (|err| < 25 ms)
#   silent audio             → rc=77 UNSCORED
#   static video             → rc=77 UNSCORED
#
# Capture exit codes DIRECTLY (never through a pipe).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/avsync_measure_hdmi.py"
FIX="$ROOT/assets/avsync/sync_24fps_blip.mp4"
OUT="$ROOT/build/avsync_measure_hdmi"
DUR=12

mkdir -p "$OUT"
rm -rf "$OUT"/*
mkdir -p "$OUT"

if [[ ! -f "$FIX" ]]; then
  echo "FAIL missing fixture $FIX"
  exit 1
fi
if [[ ! -x "$TOOL" && ! -f "$TOOL" ]]; then
  echo "FAIL missing tool $TOOL"
  exit 1
fi
chmod +x "$TOOL" || true

pass=0
fail=0

# --- build synthetic corpus ---
# 0 ms reference (PCM, shared timeline)
ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t "$DUR" \
  -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUT/inj_0.mkv"

# +250 ms: delay audio via itsoffset (container start_time) — tool must pad
ffmpeg -hide_banner -loglevel error -y \
  -i "$FIX" -itsoffset 0.250 -i "$FIX" \
  -map 0:v:0 -map 1:a:0 -t "$DUR" \
  -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUT/inj_p250.mkv"

# -200 ms: itsoffset on audio input negative → mux shifts video start_time
ffmpeg -hide_banner -loglevel error -y \
  -i "$FIX" -itsoffset -0.200 -i "$FIX" \
  -map 0:v:0 -map 1:a:0 -t "$DUR" \
  -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUT/inj_m200.mkv"

# +250 ms via adelay (silence inserted in PCM) — second positive method
ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t "$DUR" \
  -c:v libx264 -pix_fmt yuv420p -af "adelay=250|250" -c:a pcm_s16le \
  "$OUT/inj_p250_adelay.mkv"

# silence
ffmpeg -hide_banner -loglevel error -y \
  -i "$FIX" -f lavfi -i "anullsrc=r=48000:cl=mono" \
  -map 0:v:0 -map 1:a:0 -t "$DUR" -c:v copy -c:a pcm_s16le -shortest \
  "$OUT/silent.mkv"

# static black + real audio
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=320x240:r=24:d=$DUR" \
  -i "$FIX" \
  -map 0:v:0 -map 1:a:0 -t "$DUR" \
  -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le \
  "$OUT/static.mkv"

run_tool() {
  local name="$1"
  shift
  local dir="$OUT/run_$name"
  mkdir -p "$dir"
  set +e
  python3 "$TOOL" --out "$dir" --label "$name" "$@" >"$dir/stdout.txt" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

median_of() {
  local name="$1"
  # Parse median_offset_ms_raw=N.NNN
  grep -E '^median_offset_ms_raw=' "$OUT/run_$name/stdout.txt" \
    | head -1 | sed -E 's/^median_offset_ms_raw=([^ ]+).*/\1/'
}

check_rc() {
  local name="$1" expect="$2" got="$3"
  if [[ "$got" -eq "$expect" ]]; then
    echo "PASS $name rc expect=$expect true_rc=$got"
    pass=$((pass + 1))
  else
    echo "FAIL $name rc expect=$expect true_rc=$got"
    tail -n 15 "$OUT/run_$name/stdout.txt" | sed 's/^/  | /'
    fail=$((fail + 1))
  fi
}

check_median_near() {
  local name="$1" expect_ms="$2" tol_ms="$3"
  local med
  med="$(median_of "$name")"
  if [[ -z "$med" ]]; then
    echo "FAIL $name no median_offset_ms_raw in output"
    fail=$((fail + 1))
    return
  fi
  local ok
  ok="$(python3 -c "print(1 if abs(float('$med')-float('$expect_ms'))<=float('$tol_ms') else 0)")"
  if [[ "$ok" == "1" ]]; then
    echo "PASS $name median measured=$med injected=$expect_ms tol_ms=$tol_ms"
    pass=$((pass + 1))
  else
    echo "FAIL $name median measured=$med injected=$expect_ms tol_ms=$tol_ms"
    fail=$((fail + 1))
  fi
}

echo "=== RC + recovery proofs ==="

rc="$(run_tool aligned --input "$OUT/inj_0.mkv" --tol-ms 42)"
echo "CASE aligned true_rc=$rc"
check_rc aligned 0 "$rc"
check_median_near aligned 0 15

rc="$(run_tool p250 --input "$OUT/inj_p250.mkv" --tol-ms 42)"
echo "CASE p250 true_rc=$rc"
check_rc p250 2 "$rc"
check_median_near p250 250 15

rc="$(run_tool m200 --input "$OUT/inj_m200.mkv" --tol-ms 42)"
echo "CASE m200 true_rc=$rc"
check_rc m200 2 "$rc"
check_median_near m200 -200 25

rc="$(run_tool p250a --input "$OUT/inj_p250_adelay.mkv" --tol-ms 42)"
echo "CASE p250_adelay true_rc=$rc"
check_rc p250a 2 "$rc"
check_median_near p250a 250 15

rc="$(run_tool silent --input "$OUT/silent.mkv" --tol-ms 42)"
echo "CASE silent true_rc=$rc"
check_rc silent 77 "$rc"

rc="$(run_tool static --input "$OUT/static.mkv" --tol-ms 42)"
echo "CASE static true_rc=$rc"
check_rc static 77 "$rc"

# --help must work
set +e
python3 "$TOOL" --help >"$OUT/help.txt" 2>&1
hrc=$?
set -e
echo "CASE help true_rc=$hrc"
if [[ "$hrc" -eq 0 ]] && grep -q 'sign convention\|offset_ms\|calibrate' "$OUT/help.txt"; then
  echo "PASS help"
  pass=$((pass + 1))
else
  echo "FAIL help"
  fail=$((fail + 1))
fi

# calibration round-trip: treat 0 ms file as instrument baseline, apply to +250
mkdir -p "$OUT/cal" "$OUT/cal_apply"
set +e
python3 "$TOOL" --input "$OUT/inj_0.mkv" --calibrate \
  --out "$OUT/cal" --label cal \
  --calibration-out "$OUT/cal.json" --tol-ms 42 >"$OUT/cal/stdout.txt" 2>&1
crc=$?
set -e
echo "CASE calibrate true_rc=$crc"
if [[ "$crc" -eq 0 && -f "$OUT/cal.json" ]]; then
  echo "PASS calibrate wrote cal.json"
  pass=$((pass + 1))
  set +e
  python3 "$TOOL" --input "$OUT/inj_p250.mkv" \
    --calibration "$OUT/cal.json" \
    --out "$OUT/cal_apply" --label apply --tol-ms 42 \
    >"$OUT/cal_apply/stdout.txt" 2>&1
  arc=$?
  set -e
  echo "CASE cal_apply true_rc=$arc"
  # raw 250, cal ~0 → corrected ~250 → still FAIL tol 42
  check_rc cal_apply 2 "$arc"
  if grep -q 'tag=calibration_corrected' "$OUT/cal_apply/stdout.txt"; then
    echo "PASS cal_apply tagged calibration_corrected"
    pass=$((pass + 1))
  else
    echo "FAIL cal_apply missing calibration_corrected tag"
    fail=$((fail + 1))
  fi
else
  echo "FAIL calibrate rc=$crc"
  tail -n 20 "$OUT/cal/stdout.txt" 2>/dev/null | sed 's/^/  | /' || true
  fail=$((fail + 1))
fi

# Recovery table summary (measured vs injected)
{
  echo "injected_ms,measured_ms,error_ms,file"
  for pair in "0:aligned" "250:p250" "-200:m200" "250:p250a"; do
    inj="${pair%%:*}"; name="${pair##*:}"
    med="$(median_of "$name")"
    err="$(python3 -c "print(round(float('$med')-float('$inj'), 3))")"
    echo "$inj,$med,$err,$name"
  done
} | tee "$OUT/recovery_table.csv"

# Sub-frame resolution: adelay steps finer than one 30 fps capture frame (33.3 ms).
# Encode at 24 fps content; tool uses container PTS + linear luma interpolation.
# Effective resolution = RMSE of (measured - injected) across the step set.
echo "=== sub-frame adelay ladder (effective resolution) ==="
ladder_err_sq=0
ladder_n=0
ladder_pass=0
ladder_fail=0
for ms in 0 10 20 30 40 50 60 80 100 150; do
  name="lad_${ms}"
  ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t "$DUR" \
    -c:v libx264 -pix_fmt yuv420p -r 24 \
    -af "aresample=48000,adelay=${ms}|${ms}" -c:a pcm_s16le \
    "$OUT/${name}.mkv"
  rc="$(run_tool "$name" --input "$OUT/${name}.mkv" --tol-ms 500)"
  med="$(median_of "$name")"
  if [[ -z "$med" ]]; then
    echo "FAIL ladder ms=$ms no median true_rc=$rc"
    ladder_fail=$((ladder_fail + 1))
    fail=$((fail + 1))
    continue
  fi
  err="$(python3 -c "print(float('$med')-float('$ms'))")"
  abserr="$(python3 -c "print(abs(float('$err')))")"
  ladder_err_sq="$(python3 -c "print(float('$ladder_err_sq')+float('$err')**2)")"
  ladder_n=$((ladder_n + 1))
  # Per-step tol 12 ms: well under one 30 fps frame; catches regressions to frame-grid.
  ok="$(python3 -c "print(1 if abs(float('$err'))<=12.0 else 0)")"
  if [[ "$ok" == "1" ]]; then
    echo "PASS ladder injected=$ms measured=$med err=$err true_rc=$rc"
    ladder_pass=$((ladder_pass + 1))
    pass=$((pass + 1))
  else
    echo "FAIL ladder injected=$ms measured=$med err=$err true_rc=$rc"
    ladder_fail=$((ladder_fail + 1))
    fail=$((fail + 1))
  fi
  echo "$ms,$med,$err" >>"$OUT/ladder_recovery.csv"
done
if [[ "$ladder_n" -gt 0 ]]; then
  rmse="$(python3 -c "print(round((float('$ladder_err_sq')/float('$ladder_n'))**0.5, 4))")"
  echo "effective_resolution_rmse_ms=$rmse src=measured ladder_n=$ladder_n"
  echo "effective_resolution_rmse_ms=$rmse" >"$OUT/effective_resolution.txt"
  # RMSE must stay under half a 30 fps frame (16.7 ms) — the point of sub-frame interp.
  ok="$(python3 -c "print(1 if float('$rmse')<=16.7 else 0)")"
  if [[ "$ok" == "1" ]]; then
    echo "PASS effective_resolution_rmse_ms=$rmse <= 16.7"
    pass=$((pass + 1))
  else
    echo "FAIL effective_resolution_rmse_ms=$rmse > 16.7"
    fail=$((fail + 1))
  fi
fi

echo "=== SUMMARY pass=$pass fail=$fail ==="
if [[ "$fail" -ne 0 ]]; then
  echo "AVSYNC_MEASURE_HDMI_FAIL"
  exit 1
fi
echo "AVSYNC_MEASURE_HDMI_OK pass=$pass"
exit 0
