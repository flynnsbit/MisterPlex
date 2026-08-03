#!/usr/bin/env bash
# hdmi_capture_cadence.sh — multi-second HDMI capture + judder/cadence score.
#
# Parent glass instrument for 24→60 3:2 vs 30→60 2:1 vs pathological 2,2,2,4.
# Does NOT use bare ffmpeg -frames:v 1 (false black on this MJPEG grabber).
# Warm-up frames are discarded before the analysis window — same discipline as
# scripts/hdmi_capture_idle.sh.
#
# Usage:
#   scripts/hdmi_capture_cadence.sh OUT_DIR [SECONDS]
#   scripts/hdmi_capture_cadence.sh --analyze-only FRAMES_DIR
#   scripts/hdmi_capture_cadence.sh --selftest     # no device; synthetic red twin
#
# Env:
#   HDMI_DEV (default /dev/video0)  HDMI_SIZE (1920x1080)
#   HDMI_FPS (default 60)           WARMUP_FRAMES (default 20)
#   CADENCE_SECONDS (default 3)     when SECONDS arg omitted
#
# Exit:
#   0  cadence classified (PATTERN= printed) — includes FROZEN/STATIC
#   1  analyzer expect/class failure (selftest only normally)
#   2  usage
#   3  UNKNOWN_GRABBER / decode IO — never a fabric cadence claim
#   4  DEGENERATE (too few frames) — not a cadence claim
#
# Agents must not drive the device; parent owns glass capture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYZER="$ROOT/scripts/hdmi_judder_cadence.py"
DEV="${HDMI_DEV:-/dev/video0}"
SIZE="${HDMI_SIZE:-1920x1080}"
FPS="${HDMI_FPS:-60}"
WARMUP="${WARMUP_FRAMES:-20}"

usage() {
  cat <<'U' >&2
usage: hdmi_capture_cadence.sh OUT_DIR [SECONDS]
       hdmi_capture_cadence.sh --analyze-only FRAMES_DIR
       hdmi_capture_cadence.sh --selftest
U
  exit 2
}

analyze_dir() {
  local d="$1"
  shift || true
  python3 "$ANALYZER" --frames-dir "$d" "$@"
}

cmd_selftest() {
  exec bash "$ROOT/tests/unit/test_hdmi_judder_cadence.sh"
}

cmd_analyze_only() {
  local d="${1:-}"
  [[ -n "$d" && -d "$d" ]] || usage
  analyze_dir "$d"
}

cmd_capture() {
  local out_dir="${1:-}"
  local seconds="${2:-${CADENCE_SECONDS:-3}}"
  [[ -n "$out_dir" ]] || usage
  mkdir -p "$out_dir"
  local frames_dir="$out_dir/frames"
  mkdir -p "$frames_dir"

  if [[ ! -e "$DEV" ]]; then
    echo "UNKNOWN_GRABBER reason=no_device dev=$DEV" >&2
    exit 3
  fi
  if command -v fuser >/dev/null 2>&1 && fuser "$DEV" >/dev/null 2>&1; then
    echo "UNKNOWN_GRABBER reason=device_busy dev=$DEV (fuser -v $DEV)" >&2
    exit 3
  fi

  # Total frames = warm-up + analysis window. Grabber needs ~15 to lock.
  if ! [[ "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "USAGE_ERROR: SECONDS must be numeric, got $seconds" >&2
    exit 2
  fi
  local win
  win="$(python3 -c "print(max(8, int(round(float('$seconds') * float('$FPS')))))")"
  local total=$((WARMUP + win))

  echo "CAPTURE dev=$DEV size=$SIZE fps=$FPS warmup=$WARMUP window=$win total=$total out=$out_dir" >&2

  # Capture contiguous MJPEG stream to numbered PNGs (full set including warm-up).
  local raw="$out_dir/raw"
  mkdir -p "$raw"
  set +e
  ffmpeg -v error -f v4l2 -input_format mjpeg -video_size "$SIZE" -framerate "$FPS" \
    -i "$DEV" -frames:v "$total" -y "$raw/f_%04d.png" 2>"$out_dir/ffmpeg.err"
  local frc=$?
  set -e
  if [[ "$frc" -ne 0 ]]; then
    echo "UNKNOWN_GRABBER reason=ffmpeg_rc=$frc err=$(head -c 200 "$out_dir/ffmpeg.err" | tr '\n' ' ')" >&2
    exit 3
  fi

  local n_raw
  n_raw="$(ls -1 "$raw"/f_*.png 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n_raw" -lt $((WARMUP + 8)) ]]; then
    echo "DEGENERATE reason=too_few_raw n_raw=$n_raw need_ge=$((WARMUP + 8))" >&2
    exit 4
  fi

  # Discard warm-up; copy analysis window into frames/
  rm -f "$frames_dir"/f_*.png
  local i=0 idx=0
  # Sort numerically
  local f
  while IFS= read -r f; do
    i=$((i + 1))
    if [[ "$i" -le "$WARMUP" ]]; then
      continue
    fi
    idx=$((idx + 1))
    cp -f "$f" "$frames_dir/$(printf 'f_%04d.png' "$idx")"
  done < <(ls -1 "$raw"/f_*.png | sort)

  echo "WARMUP_DISCARDED=$WARMUP KEPT=$idx RAW=$n_raw" | tee "$out_dir/capture_meta.txt"
  # Also keep a mid-window still for human glance (not for cadence).
  local mid=$(( (idx / 2) + 1 ))
  if [[ -f "$frames_dir/$(printf 'f_%04d.png' "$mid")" ]]; then
    cp -f "$frames_dir/$(printf 'f_%04d.png' "$mid")" "$out_dir/still_mid.png"
  fi

  set +e
  analyze_dir "$frames_dir" | tee "$out_dir/cadence.txt"
  local arc=$?
  set -e
  exit "$arc"
}

case "${1:-}" in
  -h|--help) usage ;;
  --selftest) cmd_selftest ;;
  --analyze-only)
    shift
    cmd_analyze_only "${1:-}"
    ;;
  "") usage ;;
  *)
    cmd_capture "$@"
    ;;
esac
