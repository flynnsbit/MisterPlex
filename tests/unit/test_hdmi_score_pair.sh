#!/usr/bin/env bash
# Red-before-green for scripts/hdmi_score_pair.sh (no grabber).
# true rc of this script must be 0; internal expected fails are checked explicitly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCORE="$ROOT/scripts/hdmi_score_pair.sh"
WORKDIR="$ROOT/build/hdmi_score_pair_test"
mkdir -p "$WORKDIR"
fails=0

check() {
  local name="$1" want="$2"
  shift 2
  local out
  out="$("$SCORE" "$@" 2>&1)" || true
  echo "$out"
  if ! grep -q "VERDICT=$want" <<<"$out"; then
    echo "FAIL $name: want VERDICT=$want" >&2
    fails=$((fails + 1))
  else
    echo "OK $name -> $want"
  fi
}

python3 - "$WORKDIR" <<'PY'
import os, sys
import numpy as np
from PIL import Image
d = sys.argv[1]
W, H = 1920, 1080

def save(name, rgb):
    Image.fromarray(rgb.astype(np.uint8), "RGB").save(os.path.join(d, name))

# CONTROL-class: dark field + amber blob ~923x717 letterbox region
ctrl = np.zeros((H, W, 3), dtype=np.uint8)
x0, y0, aw, ah = 500, 180, 923, 717
# bright enough to count as ACTIVE (luma sum > 60)
ctrl[y0:y0+ah, x0:x0+aw] = (28, 26, 30)
ctrl[y0+200:y0+450, x0+300:x0+550] = (220, 140, 20)  # amber chevron-class
save("control_a.png", ctrl)
save("control_b.png", ctrl)

# Video noise deliberately avoids orange mask (R>150,G 90-200,B<90) and cyan.
def video_frame(seed, x0=100, y0=100, aw=1200, ah=700):
    rng = np.random.RandomState(seed)
    im = np.zeros((H, W, 3), dtype=np.uint8)
    # cool greys / blues — not chevron amber
    r = rng.randint(40, 120, size=(ah, aw), dtype=np.uint8)
    g = rng.randint(50, 140, size=(ah, aw), dtype=np.uint8)
    b = rng.randint(80, 200, size=(ah, aw), dtype=np.uint8)
    im[y0:y0+ah, x0:x0+aw, 0] = r
    im[y0:y0+ah, x0:x0+aw, 1] = g
    im[y0:y0+ah, x0:x0+aw, 2] = b
    return im

save("play_t0.png", video_frame(1))
save("play_t1.png", video_frame(2))

static = video_frame(3)
save("static_a.png", static)
save("static_b.png", static)

def letter_motion(seed):
    rng = np.random.RandomState(seed)
    im = np.zeros((H, W, 3), dtype=np.uint8)
    x0, y0, aw, ah = 500, 180, 923, 717
    r = rng.randint(40, 120, size=(ah, aw), dtype=np.uint8)
    g = rng.randint(50, 140, size=(ah, aw), dtype=np.uint8)
    b = rng.randint(80, 200, size=(ah, aw), dtype=np.uint8)
    im[y0:y0+ah, x0:x0+aw, 0] = r
    im[y0:y0+ah, x0:x0+aw, 1] = g
    im[y0:y0+ah, x0:x0+aw, 2] = b
    return im

save("letter_t0.png", letter_motion(10))
save("letter_t1.png", letter_motion(11))

# B3 idle: cyan corners + orange
idle = np.zeros((H, W, 3), dtype=np.uint8)
idle[80:800, 200:1400] = (31, 35, 38)
idle[100:300, 400:700] = (229, 160, 13)  # orange
idle[0:12, 0:64] = (0, 200, 255)       # cyan TL
idle[0:64, 0:12] = (0, 200, 255)
idle[-12:, -64:] = (0, 200, 255)
idle[-64:, -12:] = (0, 200, 255)
save("idle_a.png", idle)
save("idle_b.png", idle)
PY

check "N5 control pair static" "CONTROL" \
  "$WORKDIR/control_a.png" "$WORKDIR/control_b.png"
check "A synthetic motion full" "A_FABRIC_PLAY_OK" \
  "$WORKDIR/play_t0.png" "$WORKDIR/play_t1.png"
check "B2 static full" "B2_STATIC_FULL_RASTER" \
  "$WORKDIR/static_a.png" "$WORKDIR/static_b.png"
check "C1 letterbox motion" "C1_ARM_LETTERBOX" \
  "$WORKDIR/letter_t0.png" "$WORKDIR/letter_t1.png"
check "B3 idle cyan" "B3_IDLE" \
  "$WORKDIR/idle_a.png" "$WORKDIR/idle_b.png"

if [ "$fails" -ne 0 ]; then
  echo "test_hdmi_score_pair: FAIL ($fails)" >&2
  exit 1
fi
echo "test_hdmi_score_pair: PASS"
exit 0
