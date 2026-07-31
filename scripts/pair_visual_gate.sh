#!/usr/bin/env bash
# pair_visual_gate.sh — static idle / capture gate (host-side, not on-device CPU).
#
# Telemetry-only checks are insufficient: parent 2026-07-31 saw /resources=200 +
# n_daemon=1 + correct core md5 on a SOLID GREEN mixed-pair screen.
#
# Good idle (orange Plex chevron): mean luma ~38.5, std ~18
# Broken mixed pair (uniform green): mean luma ~128.4
# Grabber cold frame (NOT a device fault): uniform grey mean≈7 std=0
#   Parent recipe with -frames:v 1 produced false RED; warm-up fixes it.
#
# Usage:
#   scripts/pair_visual_gate.sh idle                  # auto-capture via hdmi_capture_idle.sh
#   PAIR_IDLE_PNG=/path/capture.png scripts/pair_visual_gate.sh idle
#   PAIR_CAPTURE_CMD='...' scripts/pair_visual_gate.sh idle
#
# Exit:
#   0  PASS visual envelope
#   8  VISUAL_REQUIRED / VISUAL_FAIL / GRABBER exhausted (hard — never claim pair success)
#   77 only if explicitly PAIR_VISUAL_ALLOW_SKIP=1 (tests); default hard-fail

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"

MODE="${1:-idle}"
PNG="${2:-${PAIR_IDLE_PNG:-}}"
OUT_DIR="${PAIR_VISUAL_OUT_DIR:-$ROOT/build/pair-visual}"
mkdir -p "$OUT_DIR"
CAPTURE_HELPER="$ROOT/scripts/hdmi_capture_idle.sh"
HDMI_DEV="${HDMI_DEV:-/dev/video0}"
MAX_GRABBER_RETRY="${PAIR_VISUAL_GRABBER_RETRIES:-2}"

if [ "$MODE" != "idle" ]; then
  echo "usage: $0 idle [png]" >&2
  echo "true rc=9"
  exit 9
fi

run_blessed_capture() {
  local dest="$1"
  echo "pair_visual: blessed capture → $dest (warm-up baked into hdmi_capture_idle.sh)"
  set +e
  HDMI_CAPTURE_OUT="$dest" "$CAPTURE_HELPER" "$dest"
  local crc=$?
  set -e
  echo "pair_visual: capture true rc=$crc"
  return "$crc"
}

can_capture() {
  if [ "${PAIR_VISUAL_NO_RECAPTURE:-0}" = "1" ]; then
    return 1
  fi
  if [ -n "${PAIR_CAPTURE_CMD:-}" ]; then
    return 0
  fi
  if [ -x "$CAPTURE_HELPER" ] && [ -e "$HDMI_DEV" ]; then
    return 0
  fi
  return 1
}

run_any_capture() {
  local dest="$1"
  if [ -n "${PAIR_CAPTURE_CMD:-}" ]; then
    mkdir -p "$(dirname "$dest")"
    set +e
    # shellcheck disable=SC2086
    # PAIR_CAPTURE_OUT is the contract: cmd must write that path (or $1).
    PAIR_CAPTURE_OUT="$dest" HDMI_CAPTURE_OUT="$dest" eval $PAIR_CAPTURE_CMD >"$OUT_DIR/capture.log" 2>&1
    local crc=$?
    set -e
    echo "pair_visual: PAIR_CAPTURE_CMD true rc=$crc dest=$dest"
    if [ ! -f "$dest" ] && [ -n "${PAIR_CAPTURE_OUT:-}" ] && [ -f "${PAIR_CAPTURE_OUT}" ]; then
      cp -f "${PAIR_CAPTURE_OUT}" "$dest"
    fi
    if [ ! -f "$dest" ] && [ -f "$OUT_DIR/idle-capture.png" ]; then
      cp -f "$OUT_DIR/idle-capture.png" "$dest"
    fi
    PNG="$dest"
    [ -f "$dest" ] || return 8
    return "$crc"
  fi
  run_blessed_capture "$dest"
  PNG="$dest"
  return $?
}

# Measure PNG → prints metrics + CLASS=... ; exit 0 pass, 8 fail, 10 grabber_not_ready
measure_png() {
  local path="$1"
  PAIR_IDLE_PNG="$path" \
  PAIR_IDLE_MEAN_MIN="${PAIR_IDLE_MEAN_MIN:-}" \
  PAIR_IDLE_MEAN_MAX="${PAIR_IDLE_MEAN_MAX:-}" \
  PAIR_IDLE_GREEN_MEAN_REJECT="${PAIR_IDLE_GREEN_MEAN_REJECT:-}" \
  python3 - <<'PY'
import os, sys
from pathlib import Path
path = Path(os.environ["PAIR_IDLE_PNG"])
try:
    from PIL import Image
except ImportError:
    print("NEED_PIL")
    print("CLASS=need_pil")
    sys.exit(9)
im = Image.open(path).convert("RGB")
im = im.resize((320, 180))
px = list(im.getdata())
n = len(px)
if n == 0:
    print("EMPTY")
    print("CLASS=empty")
    sys.exit(8)
sY = sR = sG = sB = 0.0
sY2 = 0.0
mn_c = 255
mx_c = 0
for r, g, b in px:
    y = 0.299 * r + 0.587 * g + 0.114 * b
    sY += y
    sY2 += y * y
    sR += r
    sG += g
    sB += b
    lo = min(r, g, b)
    hi = max(r, g, b)
    if lo < mn_c:
        mn_c = lo
    if hi > mx_c:
        mx_c = hi
mean = sY / n
var = max(0.0, sY2 / n - mean * mean)
std = var ** 0.5
mean_r, mean_g, mean_b = sR / n, sG / n, sB / n
chan_spread = max(mean_r, mean_g, mean_b) - min(mean_r, mean_g, mean_b)
mn = float(os.environ.get("PAIR_IDLE_MEAN_MIN") or "15")
mx = float(os.environ.get("PAIR_IDLE_MEAN_MAX") or "70")
g_reject = float(os.environ.get("PAIR_IDLE_GREEN_MEAN_REJECT") or "100")
print(f"mean_luma={mean:.2f}")
print(f"std_luma={std:.2f}")
print(f"mean_rgb={mean_r:.1f},{mean_g:.1f},{mean_b:.1f}")
print(f"minmax_rgb={mn_c},{mx_c}")
print(f"path={path}")

# Flatness is luma-std only. Do NOT require minmax_rgb<=2: a uniform
# (40,38,36) field has std_luma=0 but channel span 4 (parent false-pass class).
is_flat = std < 2.0
is_greyish = chan_spread < 8.0
is_greenish = mean_g > mean_r + 15 and mean_g > mean_b + 15

if is_flat and is_greenish and mean >= 40:
    print("FAIL class=solid_green_screen")
    print("CLASS=solid_green_screen")
    sys.exit(8)

if is_flat and is_greyish:
    print(
        "GRABBER_NOT_READY class=grabber_not_ready "
        "std_luma=%.2f mean_rgb=%.1f,%.1f,%.1f "
        "(USB grabber cold frame / no picture yet — not a device verdict)"
        % (std, mean_r, mean_g, mean_b)
    )
    print("CLASS=grabber_not_ready")
    sys.exit(10)

if is_flat:
    print("FAIL class=uniform_frame std_luma=%.2f (correct idle is never flat)" % std)
    print("CLASS=uniform_frame")
    sys.exit(8)

if mean >= g_reject and std < 25.0 and mean_g > mean_r + 15 and mean_g > mean_b + 15:
    print("FAIL class=solid_green_screen")
    print("CLASS=solid_green_screen")
    sys.exit(8)
if mean_g > mean_r + 40 and mean_g > mean_b + 40 and mean >= 90:
    print("FAIL class=green_cast_idle")
    print("CLASS=green_cast_idle")
    sys.exit(8)
if mean < mn or mean > mx:
    print(f"FAIL class=idle_mean_out_of_range want=[{mn},{mx}]")
    print("CLASS=idle_mean_out_of_range")
    sys.exit(8)
if mean < 5.0 and std < 8.0:
    print("FAIL class=black_screen mean_luma=%.2f" % mean)
    print("CLASS=black_screen")
    sys.exit(8)

print("OK class=idle_envelope")
print("CLASS=idle_envelope")
sys.exit(0)
PY
}

# Resolve initial PNG
if [ -z "$PNG" ]; then
  if [ -n "${PAIR_CAPTURE_CMD:-}" ] || can_capture; then
    PNG="$OUT_DIR/idle-capture.png"
    set +e
    run_any_capture "$PNG"
    crc=$?
    set -e
    if [ "$crc" -ne 0 ] || [ ! -f "$PNG" ]; then
      if [ "${PAIR_VISUAL_ALLOW_SKIP:-0}" = "1" ]; then
        echo "VISUAL_SKIP capture failed (PAIR_VISUAL_ALLOW_SKIP=1)"
        echo "true rc=77"
        exit 77
      fi
      echo "VISUAL_FAIL: blessed capture failed rc=$crc"
      echo "  Use: scripts/hdmi_capture_idle.sh  (warm-up baked in; never -frames:v 1 alone)"
      echo "true rc=8"
      exit 8
    fi
  fi
fi

if [ -z "$PNG" ] || [ ! -f "$PNG" ]; then
  if [ "${PAIR_VISUAL_ALLOW_SKIP:-0}" = "1" ]; then
    echo "VISUAL_SKIP no png (PAIR_VISUAL_ALLOW_SKIP=1)"
    echo "true rc=77"
    exit 77
  fi
  echo "VISUAL_REQUIRED: no idle capture PNG and no HDMI device for auto-capture."
  echo "  Blessed path (warm-up included):"
  echo "    scripts/hdmi_capture_idle.sh build/pair-visual/idle.png"
  echo "    PAIR_IDLE_PNG=... scripts/pair_visual_gate.sh idle"
  echo "  Or let the gate capture:"
  echo "    scripts/pair_visual_gate.sh idle"
  echo "    scripts/promotion_gate_check.sh verify-live   # auto if /dev/video0 present"
  echo "  NEVER: ffmpeg -frames:v 1 alone (cold grabber → false uniform grey)."
  echo "true rc=8"
  exit 8
fi

attempt=0
while [ "$attempt" -le "$MAX_GRABBER_RETRY" ]; do
  set +e
  MEAS=$(measure_png "$PNG")
  mrc=$?
  set -e
  printf '%s\n' "$MEAS"
  echo "pair_visual_measure true rc=$mrc attempt=$attempt png=$PNG"

  if [ "$mrc" -eq 0 ]; then
    echo "OK pair-visual-idle"
    echo "true rc=0"
    exit 0
  fi

  if echo "$MEAS" | grep -q NEED_PIL; then
    echo "VISUAL_FAIL: Pillow not installed on host (pip install pillow)"
    echo "true rc=8"
    exit 8
  fi

  klass=$(printf '%s\n' "$MEAS" | sed -n 's/^CLASS=//p' | tail -1)
  if [ "$mrc" -eq 10 ] || [ "$klass" = "grabber_not_ready" ]; then
    if [ "$attempt" -ge "$MAX_GRABBER_RETRY" ]; then
      echo "FAIL class=grabber_not_ready_exhausted after $((attempt + 1)) measure(s)"
      echo "  Warmed recapture still uniform — treating as real no-picture / black path."
      echo "  (Thresholds NOT loosened; detector stayed strict.)"
      echo "true rc=8"
      exit 8
    fi
    if ! can_capture; then
      echo "FAIL class=grabber_not_ready (no recapture available)"
      echo "  PNG looks like USB grabber cold frame (e.g. mean_rgb=7,7,7 std=0)."
      echo "  Re-grab with: scripts/hdmi_capture_idle.sh  (do NOT use -frames:v 1 alone)"
      echo "  Or set PAIR_IDLE_PNG to a warmed frame."
      echo "true rc=8"
      exit 8
    fi
    echo "NOTE GRABBER_NOT_READY — retry capture with baked-in warm-up (attempt $((attempt + 1)))"
    PNG="$OUT_DIR/idle-recapture-${attempt}.png"
    set +e
    run_any_capture "$PNG"
    crc=$?
    set -e
    if [ "$crc" -ne 0 ] || [ ! -f "$PNG" ]; then
      echo "VISUAL_FAIL: grabber retry capture failed rc=$crc"
      echo "true rc=8"
      exit 8
    fi
    attempt=$((attempt + 1))
    continue
  fi

  echo "VISUAL_FAIL idle gate class=${klass:-unknown}"
  echo "true rc=8"
  exit 8
done

echo "VISUAL_FAIL idle gate (exhausted)"
echo "true rc=8"
exit 8
