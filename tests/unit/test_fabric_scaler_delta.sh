#!/usr/bin/env bash
# ONE instrument / ONE window: host ffmpeg child-CPU ms/f delta for the ARM scale
# work a fabric-side scaler would remove on the 240p→624 store path.
#
# Arms (same N, same encoder, same host process accounting):
#   D240  decode 320x240 → null (no vf)
#   S240  decode 320x240 → product scale+pad 618/624 (arm_rescale path)
#   I624  decode 624x480 → crop+pad only (native 480 product, no resample)
#
# Pre-register (host x86 — NOT A9; binding device number is parent-only):
#   H1: delta_scale = S240.cpu_ms_f - D240.cpu_ms_f  > 0.5   (scale is real work)
#   H2: I624.cpu_ms_f - D240_like_decode_624 ≈ small; we only assert I624 emits pin
#   H3: S240 and I624 both emit 449280 B/frame
#
# tag=measured for host numbers. Fabric fit is NOT requested from this gate.
# true rc captured by caller outside any pipe.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/fabric_scaler_delta"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
NFRAMES="${NFRAMES:-120}"
FB=449280
EXPECTED=$((FB * NFRAMES))
VF_SCALE='scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black'
VF_CROP='crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black'

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL no ffmpeg" >&2
  exit 1
fi

mk_src() {
  local w="$1" h="$2" mp4="$3"
  [[ -f "$mp4" ]] && return 0
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=${w}x${h}:rate=24" \
    -frames:v "$NFRAMES" -c:v libx264 -pix_fmt yuv420p -preset ultrafast -crf 28 -y "$mp4"
}

SRC320="$OUT/s320.mp4"
SRC624="$OUT/s624.mp4"
mk_src 320 240 "$SRC320"
mk_src 624 480 "$SRC624"

run_arm() {
  local label="$1" src="$2" mode="$3" # null | scale | crop
  local raw="$OUT/${label}.yuv"
  local meta="$OUT/${label}.meta"
  rm -f "$raw" "$meta"
  set +e
  python3 - "$FFMPEG" "$src" "$mode" "$raw" "$NFRAMES" "$meta" "$VF_SCALE" "$VF_CROP" <<'PY'
import resource, subprocess, sys, time
ff, src, mode, raw, nframes, meta, vf_s, vf_c = sys.argv[1:9]
n = int(nframes)
cmd = [ff, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", src, "-an", "-sn"]
if mode == "null":
    cmd += ["-frames:v", str(n), "-f", "null", "-"]
elif mode == "scale":
    cmd += ["-vf", vf_s, "-pix_fmt", "yuv420p", "-frames:v", str(n), "-f", "rawvideo", "-y", raw]
elif mode == "crop":
    cmd += ["-vf", vf_c, "-pix_fmt", "yuv420p", "-frames:v", str(n), "-f", "rawvideo", "-y", raw]
else:
    sys.exit(2)
resource.getrusage(resource.RUSAGE_CHILDREN)
t0 = time.perf_counter()
p = subprocess.run(cmd, stderr=subprocess.PIPE)
wall = time.perf_counter() - t0
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = ru.ru_utime + ru.ru_stime
open(meta, "w", encoding="utf-8").write(
    f"rc={p.returncode}\nwall_s={wall:.6f}\ncpu_s={cpu:.6f}\nmode={mode}\n"
)
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
  echo "ARM $label mode=$mode rc=$rc bytes=$bytes cpu_s=$cpu cpu_ms_f=$ms_f wall_ms_f=$wall_ms_f tag=measured"
  echo "$ms_f" >"$OUT/${label}.cpu_ms_f"
  echo "$rc" >"$OUT/${label}.rc"
  echo "$bytes" >"$OUT/${label}.bytes"
  return 0
}

run_arm D240 "$SRC320" null
run_arm S240 "$SRC320" scale
run_arm I624 "$SRC624" crop

D=$(cat "$OUT/D240.cpu_ms_f")
S=$(cat "$OUT/S240.cpu_ms_f")
I=$(cat "$OUT/I624.cpu_ms_f")
SB=$(cat "$OUT/S240.bytes")
IB=$(cat "$OUT/I624.bytes")
DRC=$(cat "$OUT/D240.rc")
SRC_RC=$(cat "$OUT/S240.rc")
IRC=$(cat "$OUT/I624.rc")

DELTA=$(awk -v s="$S" -v d="$D" 'BEGIN{printf "%.4f", s-d}')
# Fabric offload upper bound on THIS host: remove scale path work (S-D).
# At 24 fps, ESTIMATED %onecpu = delta_ms_f * 24 / 10  (one core = 100 %onecpu).
PCT=$(awk -v d="$DELTA" 'BEGIN{printf "%.2f", d*24/10}')

echo "DELTA_SCALE_cpu_ms_f=$DELTA  (S240 - D240) tag=measured"
echo "FABRIC_SCALER_HOST_SAVE_ms_f=$DELTA tag=measured"
echo "FABRIC_SCALER_HOST_SAVE_est_pctonecpu_at_24fps=$PCT ESTIMATED_from_host_ms (not A9)"
echo "I624_cpu_ms_f=$I (crop+pad native; not the 240 upscale bill)"

fail=0
# H3 pin
if [[ "$SB" -ne "$EXPECTED" || "$IB" -ne "$EXPECTED" ]]; then
  echo "FAIL H3 bytes S240=$SB I624=$IB want=$EXPECTED" >&2
  fail=1
fi
if [[ "$DRC" -ne 0 || "$SRC_RC" -ne 0 || "$IRC" -ne 0 ]]; then
  echo "FAIL arm rc D=$DRC S=$SRC_RC I=$IRC" >&2
  fail=1
fi
# H1
awk -v d="$DELTA" 'BEGIN{exit !(d > 0.5)}' || {
  echo "FAIL H1 delta_scale=$DELTA not > 0.5 (scale not visible on this host)" >&2
  fail=1
}

if [[ "$fail" -ne 0 ]]; then
  echo "FABRIC_SCALER_DELTA_FAIL fail=$fail"
  exit 1
fi
echo "FABRIC_SCALER_DELTA_OK delta_ms_f=$DELTA est_pct=$PCT host_not_a9=1"
exit 0
