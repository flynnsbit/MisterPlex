#!/usr/bin/env bash
# Red-before-green for scripts/hdmi_score_pair.sh (no grabber).
# Includes parent-held real frames (ctrl720 ARM, wedge nosignal).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCORE="$ROOT/scripts/hdmi_score_pair.sh"
WORKDIR="$ROOT/build/hdmi_score_pair_test"
EV="$ROOT/docs/agent-evidence"
mkdir -p "$WORKDIR"
fails=0

check() {
  local name="$1" want="$2"
  shift 2
  local out rc
  set +e
  out="$("$SCORE" "$@" 2>&1)"
  rc=$?
  set -e
  echo "$out"
  echo "rc=$rc"
  if ! grep -q "VERDICT=$want" <<<"$out"; then
    echo "FAIL $name: want VERDICT=$want" >&2
    fails=$((fails + 1))
  else
    echo "OK $name -> $want (rc=$rc)"
  fi
}

check_rc() {
  local name="$1" want_verdict="$2" want_rc="$3"
  shift 3
  local out rc
  set +e
  out="$("$SCORE" "$@" 2>&1)"
  rc=$?
  set -e
  echo "$out"
  echo "rc=$rc"
  if ! grep -q "VERDICT=$want_verdict" <<<"$out"; then
    echo "FAIL $name: want VERDICT=$want_verdict" >&2
    fails=$((fails + 1))
  elif [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL $name: want rc=$want_rc got rc=$rc" >&2
    fails=$((fails + 1))
  else
    echo "OK $name -> $want_verdict rc=$rc"
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

ctrl = np.zeros((H, W, 3), dtype=np.uint8)
x0, y0, aw, ah = 500, 180, 923, 717
ctrl[y0:y0+ah, x0:x0+aw] = (28, 26, 30)
ctrl[y0+200:y0+450, x0+300:x0+550] = (220, 140, 20)
save("control_a.png", ctrl)
save("control_b.png", ctrl)

def video_frame(seed, x0=100, y0=100, aw=1200, ah=700):
    rng = np.random.RandomState(seed)
    im = np.zeros((H, W, 3), dtype=np.uint8)
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

idle = np.zeros((H, W, 3), dtype=np.uint8)
idle[80:800, 200:1400] = (31, 35, 38)
idle[100:300, 400:700] = (229, 160, 13)
idle[0:12, 0:64] = (0, 200, 255)
idle[0:64, 0:12] = (0, 200, 255)
idle[-12:, -64:] = (0, 200, 255)
idle[-64:, -12:] = (0, 200, 255)
save("idle_a.png", idle)
save("idle_b.png", idle)

ns = np.full((H, W, 3), 7, dtype=np.uint8)
save("nosignal.png", ns)
save("black.png", np.zeros((H, W, 3), dtype=np.uint8))
save("b1_t0.png", video_frame(5))
save("b1_t1.png", ns)
PY

check "synth CONTROL" "CONTROL_ARM_IDLE" \
  "$WORKDIR/control_a.png" "$WORKDIR/control_b.png"
check "A synthetic motion full" "A_FABRIC_PLAY_OK" \
  "$WORKDIR/play_t0.png" "$WORKDIR/play_t1.png"
check "B2 static full" "B2_STATIC_FULL_RASTER" \
  "$WORKDIR/static_a.png" "$WORKDIR/static_b.png"
check "C1 letterbox motion" "C1_ARM_LETTERBOX" \
  "$WORKDIR/letter_t0.png" "$WORKDIR/letter_t1.png"
check "B3 idle cyan" "B3_IDLE" \
  "$WORKDIR/idle_a.png" "$WORKDIR/idle_b.png"
check "E synth nosignal mean7" "E_NOSIGNAL" \
  "$WORKDIR/nosignal.png" "$WORKDIR/nosignal.png"
check "E pure black" "E_NOSIGNAL" \
  "$WORKDIR/black.png" "$WORKDIR/black.png"
check "B1 good then dead" "B1_ONE_SHOT_THEN_DEAD" \
  "$WORKDIR/b1_t0.png" "$WORKDIR/b1_t1.png"

# Beacon flip on static full raster → A via beacon_motion
python3 - "$WORKDIR" <<'PY'
import os, sys
import numpy as np
from PIL import Image
d = sys.argv[1]
H, W = 1080, 1920
def base():
    im = np.zeros((H, W, 3), dtype=np.uint8)
    im[100:800, 100:1300, 0] = 80
    im[100:800, 100:1300, 1] = 100
    im[100:800, 100:1300, 2] = 140
    return im
a = base(); b = base()
b[400:432, 1200:1232] = (0x40, 0xFF, 0x40)
Image.fromarray(a).save(os.path.join(d, "beacon_t0.png"))
Image.fromarray(b).save(os.path.join(d, "beacon_t1.png"))
PY
check "beacon lime flip static content" "A_FABRIC_PLAY_OK" \
  "$WORKDIR/beacon_t0.png" "$WORKDIR/beacon_t1.png"

check_rc "grabber flag" "UNKNOWN_GRABBER" 3 --grabber-not-ready
check_rc "grabber token" "UNKNOWN_GRABBER" 3 GRABBER_NOT_READY

if [ ! -f "$EV/ctrl720_arm.png" ] || [ ! -f "$EV/wedge_check.png" ]; then
  echo "FAIL missing real evidence PNGs under $EV" >&2
  fails=$((fails + 1))
else
  check "REAL ctrl720 self" "CONTROL_ARM_IDLE" \
    "$EV/ctrl720_arm.png" "$EV/ctrl720_arm.png"
  check "REAL wedge self" "E_NOSIGNAL" \
    "$EV/wedge_check.png" "$EV/wedge_check.png"
  check "REAL ctrl then wedge" "B1_ONE_SHOT_THEN_DEAD" \
    "$EV/ctrl720_arm.png" "$EV/wedge_check.png"
fi

if [ "$fails" -ne 0 ]; then
  echo "test_hdmi_score_pair: FAIL ($fails)" >&2
  exit 1
fi
echo "test_hdmi_score_pair: PASS"
exit 0
