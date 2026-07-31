#!/usr/bin/env bash
# pair_visual_gate.sh — static idle / capture gate (host-side, not on-device CPU).
#
# Telemetry-only checks are insufficient: parent 2026-07-31 saw /resources=200 +
# n_daemon=1 + correct core md5 on a SOLID GREEN mixed-pair screen.
#
# Good idle (orange Plex chevron): mean luma ~38.5
# Broken mixed pair (uniform green): mean luma ~128.4
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
  echo "  Parent capture example:"
  echo "    ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \\"
  echo "      -i /dev/video0 -frames:v 1 -y build/pair-visual/idle.png"
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
# Uniform green screen class: high mean, low structure, G dominates
if mean >= g_reject and std < 25.0 and mean_g > mean_r + 15 and mean_g > mean_b + 15:
    print("FAIL class=solid_green_screen")
    sys.exit(8)
if mean < mn or mean > mx:
    print(f"FAIL class=idle_mean_out_of_range want=[{mn},{mx}]")
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
