#!/usr/bin/env bash
# pair_visual_gate.sh — static idle / capture gate (host-side, not on-device CPU).
#
# Telemetry-only checks are insufficient: parent 2026-07-31 saw /resources=200 +
# n_daemon=1 + correct core md5 on a SOLID GREEN mixed-pair screen.
#
# POSITIVE ID of Plex idle chevron (amber logo structure) — NOT a luma band.
# Parent 2026-07-31: MiSTer MENU frame (CORENAME=MENU) scored mean=25.87 std=24.03
# and PASSED the old envelope while Plex was NOT loaded. Envelope is insufficient.
# Good idle: orange_frac>~0.004, centroid mid-right, mean~38–39.
# Reject: MENU/colour-bars, magenta cast, solid green, cold grabber grey.
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
# 1 if caller supplied a fixed PNG (fixture/injection). Do not replace with live HDMI
# unless PAIR_CAPTURE_CMD or PAIR_VISUAL_ALLOW_HDMI_RETRY=1 is set.
PNG_INJECTED=0
if [ -n "${PAIR_IDLE_PNG:-}" ] || [ -n "${2:-}" ]; then PNG_INJECTED=1; fi
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
  # Injected fixture PNG: never pull live HDMI unless explicitly allowed.
  if [ "${PNG_INJECTED:-0}" = "1" ] && [ -z "${PAIR_CAPTURE_CMD:-}" ] \
     && [ "${PAIR_VISUAL_ALLOW_HDMI_RETRY:-0}" != "1" ]; then
    return 1
  fi
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
# Work at modest resolution for speed; identity uses structure not full-res.
w, h = 160, 90
im = im.resize((w, h), Image.Resampling.BILINEAR)
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
orange_n = 0
magenta_n = 0
green_n = 0
orange_xs = 0.0
orange_ys = 0.0
for i, (r, g, b) in enumerate(px):
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
    # Plex idle chevron: amber/orange body (parent measured mean~38–39 with orange logo)
    if r >= 140 and r > g + 25 and r > b + 25 and g >= 50 and b < r - 10:
        orange_n += 1
        orange_xs += (i % w)
        orange_ys += (i // w)
    # Magenta/pink cast (desync class): R and B high, G depressed
    if r >= 100 and b >= 100 and g < min(r, b) - 25:
        magenta_n += 1
    if g > r + 25 and g > b + 25 and g >= 80:
        green_n += 1
mean = sY / n
var = max(0.0, sY2 / n - mean * mean)
std = var ** 0.5
mean_r, mean_g, mean_b = sR / n, sG / n, sB / n
chan_spread = max(mean_r, mean_g, mean_b) - min(mean_r, mean_g, mean_b)
orange_frac = orange_n / n
magenta_frac = magenta_n / n
green_frac = green_n / n
orange_cx = (orange_xs / orange_n / w) if orange_n else -1.0
orange_cy = (orange_ys / orange_n / h) if orange_n else -1.0
print(f"mean_luma={mean:.2f}")
print(f"std_luma={std:.2f}")
print(f"mean_rgb={mean_r:.1f},{mean_g:.1f},{mean_b:.1f}")
print(f"minmax_rgb={mn_c},{mx_c}")
print(f"orange_frac={orange_frac:.5f}")
print(f"magenta_frac={magenta_frac:.5f}")
print(f"green_frac={green_frac:.5f}")
print(f"orange_cx={orange_cx:.3f}")
print(f"orange_cy={orange_cy:.3f}")
print(f"path={path}")

is_flat = std < 2.0
is_greyish = chan_spread < 8.0
is_greenish = mean_g > mean_r + 15 and mean_g > mean_b + 15
is_magentaish = (
    magenta_frac >= 0.15
    or (mean_r >= 80 and mean_b >= 80 and mean_g < min(mean_r, mean_b) - 20)
    or (is_flat and mean_r >= 80 and mean_b >= 80 and mean_g < 40)
)

# --- ordered rejects (positive ID last) ---
if is_flat and is_greenish and mean >= 40:
    print("FAIL class=solid_green_screen")
    print("CLASS=solid_green_screen")
    sys.exit(8)

# Magenta before uniform/grey so solid magenta is not misfiled as uniform_frame
if is_magentaish:
    print("FAIL class=magenta_cast (not Plex idle chevron)")
    print("CLASS=magenta_cast")
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

if mean >= 100 and std < 25.0 and mean_g > mean_r + 15 and mean_g > mean_b + 15:
    print("FAIL class=solid_green_screen")
    print("CLASS=solid_green_screen")
    sys.exit(8)
if mean_g > mean_r + 40 and mean_g > mean_b + 40 and mean >= 90:
    print("FAIL class=green_cast_idle")
    print("CLASS=green_cast_idle")
    sys.exit(8)

# POSITIVE ID: amber Plex chevron structure (not a luma band).
# Parent proved MiSTer MENU (CORENAME=MENU, colour bars) scores mean~25.9 std~24
# inside the old [15,70] envelope with orange_frac=0 — must REJECT.
# Real chevron (idle_warm): orange_frac~0.017, centroid mid-right.
o_min = float(os.environ.get("PAIR_IDLE_ORANGE_FRAC_MIN") or "0.004")
o_max = float(os.environ.get("PAIR_IDLE_ORANGE_FRAC_MAX") or "0.12")
if orange_frac < o_min:
    print(
        "FAIL class=not_plex_idle_chevron orange_frac=%.5f want>=%.4f "
        "(MENU/colour-bar/other non-Plex screens can pass a luma envelope — rejected)"
        % (orange_frac, o_min)
    )
    print("CLASS=not_plex_idle_chevron")
    sys.exit(8)
if orange_frac > o_max:
    print("FAIL class=orange_frac_too_high orange_frac=%.5f" % orange_frac)
    print("CLASS=orange_frac_too_high")
    sys.exit(8)
# Chevron sits roughly mid-frame, not a thin edge glitch
if not (0.25 <= orange_cy <= 0.80 and 0.35 <= orange_cx <= 0.95):
    print(
        "FAIL class=orange_centroid_out_of_range cx=%.3f cy=%.3f "
        "(expected Plex chevron body, not scatter)"
        % (orange_cx, orange_cy)
    )
    print("CLASS=orange_centroid_out_of_range")
    sys.exit(8)

# Soft luma sanity AFTER identity (not the primary gate)
mn = float(os.environ.get("PAIR_IDLE_MEAN_MIN") or "12")
mx = float(os.environ.get("PAIR_IDLE_MEAN_MAX") or "80")
if mean < mn or mean > mx:
    print(f"FAIL class=idle_mean_out_of_range want=[{mn},{mx}] (after chevron id)")
    print("CLASS=idle_mean_out_of_range")
    sys.exit(8)
if mean < 5.0 and std < 8.0:
    print("FAIL class=black_screen mean_luma=%.2f" % mean)
    print("CLASS=black_screen")
    sys.exit(8)

print("OK class=plex_idle_chevron")
print("CLASS=plex_idle_chevron")
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
