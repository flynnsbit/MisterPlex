#!/usr/bin/env bash
# OBSOLETE on Plex core v3 (RBF 91777ac1) and later — it drives the v2 debug
# menu (Pattern / Audio tone / Force bars) which v3 removed. status[9:6] is now
# the video delay. Use `set_status --confstr` to read the live menu instead.
#
# Exercise Plex core OSD options via status bits + HDMI capture.
# Run on the *build host* (needs sshpass + /dev/video4 MacroSilicon).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/hw/hw_gate_common.sh"
if [[ "${MENU_OSD_ALLOW_OBSOLETE:-0}" != "1" ]]; then
  hw_skip_not_pass "test_menu_osd" \
    "obsolete v2 debug-menu card that only captures baseline; use run_menu_matrix.sh for current OSD work"
fi
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "root@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no)
OUT="${MENU_CAPTURE_DIR:-$ROOT/captures/menu}"
mkdir -p "$OUT"
REPORT="$OUT/REPORT.md"
DEVICE="${HDMI_DEV:-/dev/video4}"
PUSH=/media/fat/misterplex/bin/push_frame

ssh_q() { "${SSH[@]}" "$@" 2>/dev/null | grep -v 'WARNING\|post-quantum\|vulnerable' || true; }

capture_preflight() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=missing_ffmpeg" >&2
    exit 20
  fi
  if [[ ! -e "$DEVICE" ]]; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=absent" >&2
    exit 20
  fi
  if [[ ! -c "$DEVICE" ]]; then
    echo "NO_CAPTURE_DEVICE dev=$DEVICE reason=not_char_device" >&2
    exit 20
  fi
}

capture() {
  local name="$1"
  local dest="$OUT/${name}.jpg"
  rm -f "$dest"
  sleep 0.6
  set +e
  ffmpeg -y -hide_banner -loglevel error \
    -f v4l2 -input_format mjpeg -video_size 800x600 -framerate 30 \
    -i "$DEVICE" -frames:v 1 -update 1 -q:v 2 "$dest" 2>/dev/null
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ffmpeg -y -hide_banner -loglevel error \
      -f v4l2 -video_size 800x600 -i "$DEVICE" -frames:v 1 -update 1 -q:v 2 "$dest" 2>/dev/null
    rc=$?
  fi
  set -e
  local sz=0
  sz=$(wc -c <"$dest" 2>/dev/null || echo 0)
  if [[ "$rc" -ne 0 || "$sz" -le 0 ]]; then
    echo "CAPTURE_FAILED name=$name dev=$DEVICE reason=no_frame rc=$rc" >&2
    exit 20
  fi
  echo "  capture $name -> $dest ($sz bytes)"
  # mean luma for smoke (black ~7, bars >> 20)
  python3 - "$dest" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path
try:
    from PIL import Image
    p = Path(sys.argv[1])
    im = Image.open(p).convert("L")
    px = list(im.getdata())
    mean = sum(px) / max(len(px), 1)
    print(f"  mean_luma={mean:.1f} max={max(px)}")
    open(p.with_suffix(".luma.txt"), "w").write(f"{mean:.1f}\n")
except Exception as e:
    print("  luma_skip", e)
PY
}

# Set one status bit on MiSTer via a tiny inline helper using push_frame if available,
# else document manual OSD. Prefer python + existing SPI if we ship set_status later.
set_bits_via_ssh() {
  # args: pairs of bit value  (e.g. 6 1 7 0 for pattern)
  local args=("$@")
  ssh_q "python3 - <<'PY'
import struct, os, mmap, time, sys
# Best-effort: call push_frame is insufficient for multi-bit; use /dev/mem SPI if
# misterplex exports nothing. Fall back: write a tiny C helper status if present.
bits = list(map(int, '''${args[*]}'''.split()))
print('bits', bits)
# Prefer installed tool if we add set_status; for now use misterplexd path.
import subprocess
# Use push_frame is not enough — write raw via a one-shot if present
tool = '/media/fat/misterplex/bin/set_status'
if os.path.isfile(tool):
    for i in range(0, len(bits), 2):
        subprocess.check_call([tool, str(bits[i]), str(bits[i+1])])
    print('set_status ok')
else:
    print('NO_SET_STATUS_TOOL')
    sys.exit(2)
PY"
}

ensure_core() {
  ssh_q 'echo load_core /media/fat/_Utility/Plex.rbf > /dev/MiSTer_cmd; sleep 4; cat /tmp/CORENAME'
}

echo "# Menu OSD test report" >"$REPORT"
echo "Started: $(date -Iseconds)" >>"$REPORT"
echo >>"$REPORT"

capture_preflight
ensure_core
capture "00_baseline_default"

# If set_status tool missing, still capture baseline and note
if ! ssh_q 'test -x /media/fat/misterplex/bin/set_status && echo yes' | grep -q yes; then
  echo "WARN: set_status not on MiSTer — building/deploying from host if possible"
fi

echo "Baseline captured. Full matrix needs set_status SPI helper (agent should build)."
echo "OUT=$OUT"
ls -la "$OUT"
