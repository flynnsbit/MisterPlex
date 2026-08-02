#!/usr/bin/env bash
# Instrument floor control — MS2109 + host ffmpeg residual WITHOUT DE10-Nano.
# PARENT runs. Blocks device-attributable lipsync until floor is measured.
#
# Modes:
#   MODE=file     — host decode of fixture only (algorithm floor; NOT grabber)
#   MODE=loopback — host plays fixture to HDMI out; MS2109 captures (grabber floor)
#                   Requires physical HDMI cable: host HDMI-A-1 (or chosen) → MS2109 IN
#   MODE=static   — live capture of non-marker content (expect UNSCORED no flashes)
#
# Exit: measure rc; 77 if preflight fails / NO-DATA
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${MODE:-file}"
OUT="${OUT:-$ROOT/avsync_hdmi_out/instrument_floor}"
DUR="${DURATION:-60}"
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
MIN_PAIRS="${MIN_PAIRS:-20}"
FIXTURE="${FIXTURE:-$ROOT/assets/avsync/sync_glass_av_480p24_600s.mp4}"
# fallback shorter
if [[ ! -f "$FIXTURE" ]]; then
  FIXTURE="$ROOT/assets/avsync/sync_audio_id_glass_480p24_60s.mp4"
fi
if [[ ! -f "$FIXTURE" ]]; then
  FIXTURE="$ROOT/assets/avsync/sync_24fps_blip.mp4"
  MARKER_PERIOD_S="${MARKER_PERIOD_S:-1.0}"
fi
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-hw:0,0}"
HDMI_OUT="${HDMI_OUT:-}"   # e.g. HDMI-A-1 — required for loopback play
LABEL="${LABEL:-floor}"
mkdir -p "$OUT"

echo "=== avsync_instrument_floor ==="
echo "mode=$MODE src=caller_supplied"
echo "fixture=$FIXTURE src=caller_supplied"
echo "duration_s=$DUR marker_period_s=$MARKER_PERIOD_S min_pairs=$MIN_PAIRS src=caller_supplied"
echo "PURPOSE=measure residual wander of MS2109+host path without DE10-Nano device A/V"
echo "UNTIL_FLOOR_EXISTS=no_device_side_lipsync_number_is_attributable src=caller_supplied_parent_ERROR21"
echo "=== PRE-REGISTER ==="
echo "P_FILE: MODE=file residual_rms << live device (algorithm-only floor)"
echo "P_LOOP: MODE=loopback residual_rms is GRABBER_FLOOR; device claims must exceed this"
echo "P_TAG:  all floor numbers tag=instrument_floor not device"
echo "predictions_src=caller_supplied_pre_register"

case "$MODE" in
  file)
    echo "=== FILE algorithm floor (no grabber) ==="
    set +e
    python3 "$ROOT/tools/avsync_measure_hdmi.py" \
      --input "$FIXTURE" \
      --tol-ms 200 \
      --marker-period-s "$MARKER_PERIOD_S" \
      --min-pairs "$MIN_PAIRS" \
      --no-absolute-score \
      --warmup-frames 0 \
      --out "$OUT" \
      --label "${LABEL}_file" \
      --json-out "$OUT/${LABEL}_file_report.json" \
      >"$OUT/${LABEL}_file_stdout.txt" 2>&1
    RC=$?
    set -e
    echo "floor_file true rc=$RC"
    ;;
  loopback)
    echo "=== LOOPBACK grabber floor (host playout → MS2109) ==="
    if [[ ! -e "$VIDEO_DEV" ]]; then
      echo "VERDICT=UNSCORED rc=77 reason=no_video_dev"
      exit 77
    fi
    if fuser "$VIDEO_DEV" >/dev/null 2>&1; then
      echo "WARN $VIDEO_DEV busy"
      fuser -v "$VIDEO_DEV" 2>&1 || true
      echo "VERDICT=UNSCORED rc=77 reason=video_busy"
      exit 77
    fi
    arecord -l | head -8 || true
    echo "PREFLIGHT: HDMI cable must run host digital out → MS2109 HDMI IN"
    echo "PREFLIGHT: MiSTer must NOT be the HDMI source (unplug DE10 from grabber)"
    if [[ -n "$HDMI_OUT" ]] && command -v mpv >/dev/null 2>&1; then
      echo "starting mpv on $HDMI_OUT (background)"
      # best-effort; parent may already be playing
      mpv --ao=alsa --audio-device=hdmi --fullscreen --loop-file=no \
        --length="$DUR" "$FIXTURE" >/dev/null 2>"$OUT/mpv.err" &
      MPV_PID=$!
      sleep 2
    else
      echo "note=mpv_autoplay_skipped set HDMI_OUT= and install mpv OR play fixture manually on HDMI feeding grabber"
      MPV_PID=""
    fi
    set +e
    python3 "$ROOT/tools/avsync_measure_hdmi.py" \
      --duration "$DUR" \
      --video-dev "$VIDEO_DEV" \
      --audio-dev "$AUDIO_DEV" \
      --tol-ms 200 \
      --marker-period-s "$MARKER_PERIOD_S" \
      --min-pairs "$MIN_PAIRS" \
      --no-absolute-score \
      --warmup-frames 20 \
      --out "$OUT" \
      --label "${LABEL}_loop" \
      --json-out "$OUT/${LABEL}_loop_report.json" \
      --decode-src caller_supplied \
      >"$OUT/${LABEL}_loop_stdout.txt" 2>&1
    RC=$?
    set -e
    echo "floor_loop true rc=$RC"
    if [[ -n "${MPV_PID:-}" ]]; then
      kill "$MPV_PID" 2>/dev/null || true
      wait "$MPV_PID" 2>/dev/null || true
    fi
    ;;
  *)
    echo "VERDICT=UNSCORED rc=77 reason=unknown_MODE"
    exit 77
    ;;
esac

# Surface floor metrics
STDOUT=$(ls "$OUT"/${LABEL}_*_stdout.txt 2>/dev/null | tail -1 || true)
if [[ -n "${STDOUT:-}" ]]; then
  grep -E '^(SCORE |VERDICT=|timing_class=|residual_rms|detrended_p95|detrended_max|excess_wander|n_pairs=|inter_flash|video_quant|wander_rms_tol)' \
    "$STDOUT" || true
fi

# Beat model for this run
REP=$(ls "$OUT"/${LABEL}_*_report.json 2>/dev/null | tail -1 || true)
if [[ -n "${REP:-}" ]]; then
  python3 "$ROOT/tools/avsync_capture_beat.py" \
    --report "$REP" --marker-period-s "$MARKER_PERIOD_S" \
    | tee "$OUT/${LABEL}_beat.txt"
fi

# Stamp floor summary JSON
python3 - "$OUT" "$LABEL" "$MODE" "$RC" <<'PY'
import json, re, sys
from pathlib import Path
out, label, mode, rc = sys.argv[1:5]
out_p = Path(out)
text = ""
for p in out_p.glob(f"{label}_*_stdout.txt"):
    text += p.read_text(errors="replace")

def g(pat, cast=float):
    m = re.search(pat, text, re.M)
    if not m: return None
    try: return cast(m.group(1))
    except Exception: return None

doc = {
    "tool": "avsync_instrument_floor",
    "mode": mode,
    "mode_src": "caller_supplied",
    "measure_rc": int(rc),
    "residual_rms_ms": g(r"residual_rms_ms=([-\d.eE]+)"),
    "residual_rms_ms_src": "measured" if g(r"residual_rms_ms=([-\d.eE]+)") is not None else "NO-DATA",
    "detrended_p95_abs_ms": g(r"detrended_p95_abs_ms=([-\d.eE]+)"),
    "detrended_p95_abs_ms_src": "measured" if g(r"detrended_p95_abs_ms=") else "NO-DATA",
    "detrended_max_abs_ms": g(r"detrended_max_abs_ms=([-\d.eE]+)"),
    "detrended_max_abs_ms_note": "fragile_not_headline",
    "excess_wander_rms_ms": g(r"excess_wander_rms_ms=([-\d.eE]+)"),
    "wander_rms_tol_ms": g(r"wander_rms_tol_ms=([-\d.eE]+)"),
    "video_quant_rms_ms": g(r"video_quant_rms_ms=([-\d.eE]+)"),
    "timing_class": (re.search(r"timing_class=([A-Z_]+)", text) or [None, None])[1],
    "n_pairs": g(r"^n_pairs=(\d+)", int),
    "tag": "instrument_floor",
    "device_attributable": False,
    "honesty": (
        "This residual is the instrument/path floor for the chosen MODE. "
        "Device lipsync is only attributable if it exceeds this floor with "
        "margin; until loopback floor exists, live DE10 numbers are NOT device claims."
    ),
}
path = out_p / f"{label}_summary.json"
path.write_text(json.dumps(doc, indent=2) + "\n")
print(f"floor_summary_json={path}")
for k in ("residual_rms_ms", "detrended_p95_abs_ms", "excess_wander_rms_ms",
          "video_quant_rms_ms", "wander_rms_tol_ms", "timing_class", "n_pairs"):
    print(f"floor_{k}={doc.get(k)} src={doc.get(k+'_src', 'measured_or_NO-DATA')} tag=instrument_floor")
print(f"device_attributable=false src=caller_supplied")
print(f"VERDICT=FLOOR_MEASURED mode={mode} rc={rc}")
PY

exit "$RC"
