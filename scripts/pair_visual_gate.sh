#!/usr/bin/env bash
# pair_visual_gate.sh — static idle / capture gate (host-side, not on-device CPU).
#
# Telemetry-only checks are insufficient: parent 2026-07-31 saw /resources=200 +
# n_daemon=1 + correct core md5 on a SOLID GREEN mixed-pair screen.
#
# Good idle (orange Plex chevron): mean luma ~38.5
# Broken mixed pair (uniform green): mean luma ~128.4
#
# IDENTITY-NOT-POSE (parent 2026-07-31): do NOT gate on logo centroid position
# (orange_cx/cy). IDLE_SCREEN=screensaver deliberately moves the logo; a
# 0.25<=cy<=0.80 bound false-REDs healthy frames. Identity = color/structure
# envelope + menu_color_bars reject, never pose.
#
# Usage:
#   PAIR_IDLE_PNG=/path/capture.png scripts/pair_visual_gate.sh idle
#   PAIR_CAPTURE_CMD='ffmpeg ...' scripts/pair_visual_gate.sh idle
#   scripts/pair_visual_gate.sh idle /path/capture.png
#
# Exit:
#   0  PASS visual envelope
#   8  VISUAL_REQUIRED / VISUAL_FAIL (hard — never claim pair success)
#   77 only if explicitly PAIR_VISUAL_ALLOW_SKIP=1 (tests); default hard-fail

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"

MODE="${1:-idle}"
PNG="${2:-${PAIR_IDLE_PNG:-}}"
OUT_DIR="${PAIR_VISUAL_OUT_DIR:-$ROOT/build/pair-visual}"
mkdir -p "$OUT_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ "$MODE" != "idle" ]; then
  echo "usage: $0 idle [png]" >&2
  echo "true rc=9"
  exit 9
fi

if [ -z "$PNG" ]; then
  if [ -n "${PAIR_CAPTURE_CMD:-}" ]; then
    PNG="$OUT_DIR/idle-capture.png"
    set +e
    # shellcheck disable=SC2086
    eval $PAIR_CAPTURE_CMD >"$OUT_DIR/capture.log" 2>&1
    crc=$?
    set -e
    echo "pair_visual: capture true rc=$crc"
    # Caller must write PAIR_IDLE_PNG or have capture cmd write $PNG
    if [ -n "${PAIR_CAPTURE_OUT:-}" ]; then
      PNG="$PAIR_CAPTURE_OUT"
    fi
  fi
fi

if [ -z "$PNG" ] || [ ! -f "$PNG" ]; then
  if [ "${PAIR_VISUAL_ALLOW_SKIP:-0}" = "1" ]; then
    echo "VISUAL_SKIP no png (PAIR_VISUAL_ALLOW_SKIP=1)"
    echo "true rc=77"
    exit 77
  fi
  echo "VISUAL_REQUIRED: no idle capture PNG."
  echo "  Set PAIR_IDLE_PNG=/path/to/frame.png or PAIR_CAPTURE_CMD=..."
  echo "  Parent capture (WARM-UP REQUIRED — bare -frames:v 1 is DEFECTIVE):"
  echo "    scripts/capture_hdmi_frame.sh build/pair-visual/idle.png"
  echo "    # ffmpeg … -vf 'select=gte(n\\,20)' -frames:v 1 -y build/pair-visual/idle.png"
  echo "  Unset visual must NOT claim pair success (green-screen class)."
  echo "true rc=8"
  exit 8
fi

# Measure mean luma + green dominance + near-uniformity (host Python).
set +e
MEAS=$(PAIR_IDLE_PNG="$PNG" PAIR_IDLE_MEAN_MIN="$PAIR_IDLE_MEAN_MIN" \
  PAIR_IDLE_MEAN_MAX="$PAIR_IDLE_MEAN_MAX" \
  PAIR_IDLE_GREEN_MEAN_REJECT="$PAIR_IDLE_GREEN_MEAN_REJECT" \
  python3 - <<'PY'
import os, sys
from pathlib import Path
path = Path(os.environ["PAIR_IDLE_PNG"])
try:
    from PIL import Image
except ImportError:
    print("NEED_PIL")
    sys.exit(9)
im = Image.open(path).convert("RGB")
# Downsample for speed
im = im.resize((320, 180))
px = list(im.getdata())
n = len(px)
if n == 0:
    print("EMPTY")
    sys.exit(8)
sY = sR = sG = sB = 0.0
# sample variance via second moment of Y
sY2 = 0.0
for r, g, b in px:
    y = 0.299 * r + 0.587 * g + 0.114 * b
    sY += y
    sY2 += y * y
    sR += r
    sG += g
    sB += b
mean = sY / n
var = max(0.0, sY2 / n - mean * mean)
std = var ** 0.5
mean_r, mean_g, mean_b = sR / n, sG / n, sB / n
mn = float(os.environ.get("PAIR_IDLE_MEAN_MIN", "15"))
mx = float(os.environ.get("PAIR_IDLE_MEAN_MAX", "70"))
g_reject = float(os.environ.get("PAIR_IDLE_GREEN_MEAN_REJECT", "100"))
print(f"mean_luma={mean:.2f}")
print(f"std_luma={std:.2f}")
print(f"mean_rgb={mean_r:.1f},{mean_g:.1f},{mean_b:.1f}")
print(f"path={path}")
# Uniformity: a correct idle screen is never near-byte-identical flat field.
# Parent: broken mixed-pair was uniform green, byte-identical across frames.
# Mean alone is blind (correct starfield mean 0.2 vs garbage 66).
if std < 8.0:
    print("FAIL class=uniform_frame std_luma=%.2f (correct idle is never flat)" % std)
    sys.exit(8)
# Uniform green screen class: high mean, low structure, G dominates
if mean >= g_reject and std < 25.0 and mean_g > mean_r + 15 and mean_g > mean_b + 15:
    print("FAIL class=solid_green_screen")
    sys.exit(8)
if mean_g > mean_r + 40 and mean_g > mean_b + 40 and mean >= 90:
    print("FAIL class=green_cast_idle")
    sys.exit(8)
if mean < mn or mean > mx:
    print(f"FAIL class=idle_mean_out_of_range want=[{mn},{mx}]")
    sys.exit(8)
# MENU / color-bar class (parent postboot.png CORENAME=MENU):
# horizontal stripes → each row nearly uniform, row-means vary a lot.
# Correct Plex idle (orange chevron on dark) has 2D structure, not pure bands.
w, h = im.size
arr = list(im.getdata())
# rebuild row luma means + within-row std
import statistics
row_means = []
row_stds = []
for y in range(h):
    ys = []
    for x in range(w):
        r, g, b = arr[y * w + x]
        ys.append(0.299 * r + 0.587 * g + 0.114 * b)
    row_means.append(sum(ys) / len(ys))
    if len(ys) > 1:
        mu = row_means[-1]
        row_stds.append((sum((v - mu) ** 2 for v in ys) / len(ys)) ** 0.5)
    else:
        row_stds.append(0.0)
mean_row_std = sum(row_stds) / max(1, len(row_stds))
row_mean_spread = (sum((v - mean) ** 2 for v in row_means) / max(1, len(row_means))) ** 0.5
print(f"mean_within_row_std={mean_row_std:.2f}")
print(f"row_mean_spread={row_mean_spread:.2f}")
# Color bars: very low horizontal structure, high vertical banding.
if mean_row_std < 12.0 and row_mean_spread > 18.0:
    print("FAIL class=menu_color_bars (horizontal stripes — CORENAME=MENU class, not Plex idle)")
    sys.exit(8)
print("OK class=idle_envelope")
sys.exit(0)
PY
)
vrc=$?
set -e
printf '%s\n' "$MEAS"
echo "pair_visual_measure true rc=$vrc"
if [ "$vrc" -eq 0 ]; then
  echo "OK pair-visual-idle"
  echo "true rc=0"
  exit 0
fi
if echo "$MEAS" | grep -q NEED_PIL; then
  echo "VISUAL_FAIL: Pillow not installed on host (pip install pillow)"
  echo "true rc=8"
  exit 8
fi
echo "VISUAL_FAIL idle gate (see class= above)"
echo "true rc=8"
exit 8
