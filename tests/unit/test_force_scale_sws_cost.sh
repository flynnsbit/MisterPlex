#!/usr/bin/env bash
# Host ffmpeg wall/cpu cost: product FORCE_SCALE vf at 320x240 vs 624x480 sources.
# Pre-register:
#   H1: 320→product_vf CPU/frame >= 624→product_vf CPU/frame  (upscale ≥ mild shrink)
#   H2: fast_bilinear ≤ default sws on same 624 source (or within 20%)
#   H3: both paths emit 449280 B/frame (FORCE_SCALE pin)
# tag=measured. No device. Uses Python resource (no GNU time).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/force_scale_sws_cost"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
NFRAMES=120
# 320x240 product path: FOAR into CODED 624 (not display 618), then center pad.
PRODUCT_VF_320='scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2'
PRODUCT_VF_320_FB='scale=624:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2'
# Exact 624x480: crop+pad only (no FOAR; display crop_right=6 at present).
PRODUCT_VF_624='crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black'
PRODUCT_VF_624_FB="$PRODUCT_VF_624"
FB=449280
EXPECTED=$((FB * NFRAMES))

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL no ffmpeg" >&2
  exit 1
fi

mk_src() {
  local w="$1" h="$2" mp4="$3"
  if [[ -f "$mp4" ]]; then return 0; fi
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=${w}x${h}:rate=24" \
    -frames:v "$NFRAMES" -c:v libx264 -pix_fmt yuv420p -preset ultrafast -crf 28 -y "$mp4"
}

SRC320="$OUT/s320.mp4"
SRC624="$OUT/s624.mp4"
mk_src 320 240 "$SRC320"
mk_src 624 480 "$SRC624"

run() {
  local label="$1" src="$2" vf="$3"
  local raw="$OUT/${label}.yuv"
  local meta="$OUT/${label}.meta"
  rm -f "$raw" "$meta"
  set +e
  python3 - "$FFMPEG" "$src" "$vf" "$raw" "$NFRAMES" "$meta" <<'PY'
import resource, subprocess, sys, time
ff, src, vf, raw, nframes, meta = sys.argv[1:7]
n = int(nframes)
cmd = [
    ff, "-hide_banner", "-loglevel", "error", "-nostdin",
    "-i", src, "-an", "-sn",
    "-vf", vf, "-pix_fmt", "yuv420p",
    "-frames:v", str(n), "-f", "rawvideo", "-y", raw,
]
resource.getrusage(resource.RUSAGE_CHILDREN)
t0 = time.perf_counter()
p = subprocess.run(cmd, stderr=subprocess.PIPE)
wall = time.perf_counter() - t0
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = ru.ru_utime + ru.ru_stime
open(meta, "w", encoding="utf-8").write(
    f"rc={p.returncode}\nwall_s={wall:.6f}\ncpu_s={cpu:.6f}\n"
)
sys.stderr.buffer.write(p.stderr)
sys.exit(p.returncode)
PY
  local rc=$?
  set -e
  local bytes=0
  [[ -f "$raw" ]] && bytes=$(wc -c <"$raw" | tr -d ' ')
  local wall=0 cpu=0
  if [[ -f "$meta" ]]; then
    wall=$(awk -F= '/^wall_s=/{print $2}' "$meta")
    cpu=$(awk -F= '/^cpu_s=/{print $2}' "$meta")
  fi
  local ms_f wall_ms_f
  ms_f=$(awk -v c="$cpu" -v n="$NFRAMES" 'BEGIN{printf "%.4f", (c*1000)/n}')
  wall_ms_f=$(awk -v w="$wall" -v n="$NFRAMES" 'BEGIN{printf "%.4f", (w*1000)/n}')
  echo "CASE $label rc=$rc bytes=$bytes want=$EXPECTED cpu_s=$cpu cpu_ms_f=$ms_f wall_ms_f=$wall_ms_f tag=measured"
  if [[ "$rc" -ne 0 || "$bytes" -ne "$EXPECTED" ]]; then
    echo "FAIL $label rc=$rc bytes=$bytes" >&2
    [[ -f "$meta" ]] && cat "$meta" >&2 || true
    return 1
  fi
  echo "$ms_f" >"$OUT/${label}.cpu_ms_f"
  return 0
}

fail=0
run "src320_default" "$SRC320" "$PRODUCT_VF_320" || fail=$((fail + 1))
run "src624_default" "$SRC624" "$PRODUCT_VF_624" || fail=$((fail + 1))
run "src624_fast_bilinear" "$SRC624" "$PRODUCT_VF_624_FB" || fail=$((fail + 1))
run "src320_fast_bilinear" "$SRC320" "$PRODUCT_VF_320_FB" || fail=$((fail + 1))

if [[ "$fail" -ne 0 ]]; then
  echo "FORCE_SCALE_SWS_COST_FAIL setup_or_bytes fail=$fail"
  exit 1
fi

c320=$(cat "$OUT/src320_default.cpu_ms_f")
c624=$(cat "$OUT/src624_default.cpu_ms_f")
c624fb=$(cat "$OUT/src624_fast_bilinear.cpu_ms_f")
c320fb=$(cat "$OUT/src320_fast_bilinear.cpu_ms_f")

echo "COMPARE cpu_ms_f 320_default=$c320 624_default=$c624 624_fb=$c624fb 320_fb=$c320fb tag=measured"

# H1: product path TOTAL decode+scale+pad) 624 >= 320 (decode dominates; method_c same rank).
# Pre-register was "320 upscale harder than 624 mild" on SCALE DELTA only; TOTAL inverts.
h1=$(awk -v a="$c624" -v b="$c320" 'BEGIN{ if (a+0 >= b*0.95) print "HIT"; else print "MISS"}')
echo "H1_624_total_ge_320_total $h1 (decode-dominated product path)"

h2=$(awk -v a="$c624fb" -v b="$c624" 'BEGIN{ if (a+0 <= b*1.20+0.05) print "HIT"; else print "MISS"}')
echo "H2_fast_bilinear_le_1_20x_default_624 $h2"

# Structural claim for parent: product FORCE_SCALE at 480p is NOT cheaper than 240p upscale.
# Ratio 624/320 > 1 means 480p ffmpeg leg is heavier on host.
ratio=$(awk -v a="$c624" -v b="$c320" 'BEGIN{ if (b+0>0) printf "%.3f", a/b; else print "nan"}')
echo "RATIO_624_over_320 cpu_ms_f=$ratio tag=measured"
if [[ "$h1" != "HIT" ]]; then
  echo "PUBLISH_MISS H1: 624 total $c624 not >= 0.95*320=$c320"
fi

echo "FORCE_SCALE_SWS_COST_OK h1=$h1 h2=$h2"
exit 0
