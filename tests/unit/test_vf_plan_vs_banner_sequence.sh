#!/usr/bin/env bash
# Sequencing lock: vf plan freezes BEFORE spawn; banner AFTER; cannot rebuild vf.
# Observed defect class: plan on PMS claim (delivery_verified=0), MEASURED lands
# later (parent field 624x350 after crop freeze).
#
# Also host-measures lavfi spawn→banner latency (tag=measured host_lavfi).
# Device PMS spawn_to_banner_ms is UNKNOWN here — parent greps device log.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
HPP="$ROOT/arm/misterplexd/media_player.hpp"
VF="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"
MAIN="$ROOT/arm/misterplexd/main.cpp"
PR="$ROOT/arm/misterplexd/plex_resolve.cpp"
fail=0
pass=0
applied=0

check() {
  local name="$1" file="$2" pat="$3"
  if rg -n --fixed-strings "$pat" "$file" >/dev/null; then
    echo "PASS $name"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL $name missing: $pat" >&2
    fail=$((fail + 1))
  fi
}

# --- A: plan freeze before spawn (source order via line numbers) ---
plan_line=$(rg -n 'const FfmpegVfPlan vfPlan = buildFfmpegVideoFilter' "$MP" | head -1 | cut -d: -f1)
spawn_line=$(rg -n 'spawnFfmpeg\(args, vpipe' "$MP" | head -1 | cut -d: -f1)
pump_line=$(rg -n 'void MediaPlayer::ffmpegStderrPump' "$MP" | head -1 | cut -d: -f1)
meas_line=$(rg -n 'media: MEASURED_DELIVERY delivered_geom=' "$MP" | head -1 | cut -d: -f1)
mid_line=$(rg -n 'cannot rebuild vf' "$MP" | head -1 | cut -d: -f1)
if [[ -n "$plan_line" && -n "$spawn_line" && "$plan_line" -lt "$spawn_line" ]]; then
  echo "PASS SEQ_plan_before_spawn plan_line=$plan_line spawn_line=$spawn_line"
  pass=$((pass + 1)); applied=$((applied + 1))
else
  echo "FAIL SEQ_plan_before_spawn plan=$plan_line spawn=$spawn_line" >&2
  fail=$((fail + 1))
fi
if [[ -n "$meas_line" && -n "$spawn_line" && "$meas_line" -lt "$spawn_line" ]]; then
  # MEASURED log string is inside pump (defined before spawn call site) — OK
  echo "PASS SEQ_MEASURED_string_in_pump_def meas_line=$meas_line (def before call)"
  pass=$((pass + 1)); applied=$((applied + 1))
else
  echo "FAIL SEQ_MEASURED_string" >&2
  fail=$((fail + 1))
fi
if [[ -n "$mid_line" ]]; then
  echo "PASS SEQ_mid_stream_cannot_rebuild line=$mid_line"
  pass=$((pass + 1)); applied=$((applied + 1))
else
  echo "FAIL SEQ_mid_stream_cannot_rebuild" >&2
  fail=$((fail + 1))
fi

check SEQ_SPAWN_VF_FROZEN_log "$MP" 'SPAWN_VF_FROZEN'
check SEQ_spawn_to_banner_field "$MP" 'spawn_to_banner_ms='
check SEQ_vf_frozen_note "$MP" 'banner_arrives_after_spawn_cannot_rebuild_vf'
check SEQ_mid_stream_flag "$MP" 'MID_STREAM_CHANGE='
check SEQ_delivery_verified_only_measured "$MP" 'deliveryGeometryVerifiedFromBasis("measured")'
check SEQ_session_resets_verified "$MP" 'Session measure starts unverified'
check SEQ_vf_on_argv "$MP" 'args.push_back("-vf")'
check SEQ_ffmpeg_spawn_mono_member "$HPP" 'ffmpegSpawnMonoMs_'

# Play-time claim is never measured (main).
check SEQ_main_transcode_request_basis "$MAIN" 'deliveryBasis = "transcode_request"'
check SEQ_main_library_claim "$MAIN" 'deliveryBasis = "library_media"'
check SEQ_main_verified_from_basis "$MAIN" 'deliveryGeometryVerifiedFromBasis(deliveryBasis)'
check SEQ_pred_fit_log_only "$MAIN" 'predicted_square_fit='
check SEQ_pred_note_ceiling "$MAIN" 'videoResolution_is_ceiling_not_exact'

# Bitrate is OUR request param (not pure PMS-side).
check BR_maxVideoBitrate_url "$PR" 'maxVideoBitrate='
check BR_weak_ladder_field "$PR" 'weak.maxVideoBitrateKbps'
check BR_videoResolution_ceiling_comment "$PR" 'videoResolution=WxH is a CEILING'

# ffmpeg_vf documents freeze-before-banner.
check VF_comment_banner_after "$VF" 'delivery_geometry_verified stays 0 until the ffmpeg banner arrives'

# --- B: host lavfi banner latency (NOT device PMS) ---
FFMPEG="${FFMPEG:-ffmpeg}"
if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL host_banner: ffmpeg missing" >&2
  fail=$((fail + 1))
else
  OUT="$ROOT/build/vf_banner_latency"
  mkdir -p "$OUT"
  python3 - "$FFMPEG" "$OUT" <<'PY'
import re, subprocess, sys, time, os
ff, out_dir = sys.argv[1], sys.argv[2]
geom_re = re.compile(r"(\d{2,5})x(\d{2,5})")
def trial(lavfi):
    cmd = [ff, "-hide_banner", "-stats", "-loglevel", "info", "-nostdin",
           "-f", "lavfi", "-i", lavfi, "-an", "-frames:v", "2", "-f", "null", "-"]
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
    first = None
    buf = b""
    while True:
        chunk = p.stderr.read(128)
        if not chunk:
            break
        buf += chunk
        text = buf.decode("utf-8", "replace")
        if first is None:
            for line in re.split(r"[\r\n]+", text):
                if "Stream" in line and "Video" in line and geom_re.search(line):
                    first = time.perf_counter() - t0
                    break
    rc = p.wait()
    wall = time.perf_counter() - t0
    return rc, first, wall

samples = []
fail = 0
for i in range(5):
    rc, b, w = trial("testsrc2=size=624x350:rate=24")
    if rc != 0 or b is None:
        print(f"FAIL host_banner trial={i} rc={rc} banner=NO-DATA", file=sys.stderr)
        fail += 1
        continue
    samples.append(b)
    print(f"HOST_LAVFI_BANNER trial={i} banner_s={b:.4f} wall_s={w:.4f} tag=measured_host_lavfi")
if fail:
    sys.exit(1)
samples.sort()
med = samples[len(samples)//2]
# Sanity bounds: banner must be sub-second on host; not a device claim.
if med <= 0 or med > 2.0:
    print(f"FAIL host_banner median={med} out of (0,2]s", file=sys.stderr)
    sys.exit(1)
print(f"HOST_LAVFI_BANNER_OK n={len(samples)} median_s={med:.4f} min_s={samples[0]:.4f} max_s={samples[-1]:.4f} tag=measured_host_lavfi")
print("NOTE device_PMS_spawn_to_banner_ms=UNKNOWN — parent greps MEASURED_DELIVERY spawn_to_banner_ms=")
sys.exit(0)
PY
  brc=$?
  echo "host_banner_python true rc=$brc"
  if [[ "$brc" -eq 0 ]]; then
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    fail=$((fail + 1))
  fi
fi

# applied-match floor (no-op mutation cannot pass with 0 checks)
want=20
if [[ "$applied" -lt "$want" ]]; then
  echo "FAIL applied_match=$applied want>=$want" >&2
  fail=$((fail + 1))
else
  echo "PASS applied_match=$applied want>=$want"
  pass=$((pass + 1))
fi

echo "SUMMARY pass=$pass fail=$fail applied=$applied"
if [[ "$fail" -ne 0 ]]; then
  echo "TEST_VF_PLAN_VS_BANNER_SEQUENCE_FAIL"
  exit 1
fi
echo "TEST_VF_PLAN_VS_BANNER_SEQUENCE_OK"
exit 0
