#!/usr/bin/env bash
# Score two HDMI captures for the PLAYING capture contract.
# Usage:
#   scripts/hdmi_score_pair.sh T0.png T1.png
#   scripts/hdmi_score_pair.sh --grabber-not-ready
#   scripts/hdmi_score_pair.sh GRABBER_NOT_READY
#
# Exit codes:
#   0  scored a real frame pair (VERDICT=A/B/C/D/E/CONTROL/…)
#   2  usage / shape error
#   3  UNKNOWN_GRABBER — capture never produced frames; NOT a fabric verdict
#
# Parent: if hdmi_capture_idle.sh rc=1, call:
#   scripts/hdmi_score_pair.sh --grabber-not-ready
# Soft-skip/unknown must never be reported as fabric FAIL or PASS.
set -euo pipefail

if [ "${1:-}" = "--grabber-not-ready" ] || [ "${1:-}" = "GRABBER_NOT_READY" ] \
  || [ "${2:-}" = "--grabber-not-ready" ] || [ "${2:-}" = "GRABBER_NOT_READY" ]; then
  echo "T0= GRABBER_NOT_READY T1=GRABBER_NOT_READY"
  echo "VERDICT=UNKNOWN_GRABBER"
  echo "NOTE=hdmi_capture_idle rc=1 or grabber busy/absent — not a product state"
  exit 3
fi

T0="${1:?usage: hdmi_score_pair.sh T0.png T1.png | --grabber-not-ready}"
T1="${2:?usage: hdmi_score_pair.sh T0.png T1.png | --grabber-not-ready}"

for f in "$T0" "$T1"; do
  if [ ! -f "$f" ]; then
    echo "USAGE_ERROR: missing file: $f" >&2
    echo "VERDICT=UNKNOWN_GRABBER" >&2
    exit 3
  fi
  if [ ! -s "$f" ]; then
    echo "USAGE_ERROR: empty file: $f" >&2
    echo "VERDICT=UNKNOWN_GRABBER" >&2
    exit 3
  fi
  if [ -f "${f}.grabber_status" ] && grep -q 'GRABBER_NOT_READY' "${f}.grabber_status" 2>/dev/null; then
    echo "T0=$T0 T1=$T1"
    echo "VERDICT=UNKNOWN_GRABBER"
    echo "NOTE=sidecar ${f}.grabber_status"
    exit 3
  fi
done

exec python3 - "$T0" "$T1" <<'PY'
import sys
import numpy as np
from PIL import Image

def stats(path):
    im = np.array(Image.open(path).convert("RGB")).astype(np.int16)
    R, G, B = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    lum = im.sum(axis=2) / 3.0
    orange = int(((R > 150) & (G > 90) & (G < 200) & (B < 90)).sum())
    cyan = int(((R < 80) & (G > 140) & (B > 180)).sum())
    magenta = int(((R > 180) & (G < 80) & (B > 100) & (B < 200)).sum())
    tot = im.sum(axis=2)
    rows = np.where(tot.max(axis=1) > 60)[0]
    cols = np.where(tot.max(axis=0) > 60)[0]
    if len(rows) and len(cols):
        aw = int(cols[-1] - cols[0] + 1)
        ah = int(rows[-1] - rows[0] + 1)
        ax0, ax1 = int(cols[0]), int(cols[-1])
    else:
        aw = ah = ax0 = ax1 = 0
    return {
        "path": path,
        "mean": float(lum.mean()),
        "std": float(lum.std()),
        "orange": orange,
        "cyan": cyan,
        "magenta": magenta,
        "aw": aw,
        "ah": ah,
        "area": aw * ah,
        "ax0": ax0,
        "ax1": ax1,
        "lum": lum,
        "im": im,
    }

def is_nosignal(s):
    """Genuine no-signal / hung SoC.

    Measured wedge_check.png: MEAN=7.0 STD=0.0 ACTIVE=0x0
    Pure black: MEAN=0 STD=0 ACTIVE=0x0
    Key: STD≈0 and no active region — not mean==0 alone.
    """
    return s["std"] < 0.5 and s["area"] == 0

a = stats(sys.argv[1])
b = stats(sys.argv[2])
if a["im"].shape != b["im"].shape:
    print(f"SHAPE_MISMATCH {a['im'].shape} vs {b['im'].shape}", file=sys.stderr)
    print("VERDICT=UNKNOWN_GRABBER", file=sys.stderr)
    sys.exit(2)

d = np.abs(a["lum"] - b["lum"])
diff_mean = float(d.mean())
diff_px = int((d > 20.0).sum())

aw, ah, area = b["aw"], b["ah"], b["area"]
mean, std = b["mean"], b["std"]
orange, cyan, magenta = b["orange"], b["cyan"], b["magenta"]
ns0, ns1 = is_nosignal(a), is_nosignal(b)

CTRL_AW, CTRL_AH = 923, 717
CTRL_AREA = CTRL_AW * CTRL_AH
PASS_AW, PASS_AH = 1100, 680
PASS_AREA = PASS_AW * PASS_AH
PASS_DIFF_PX = 8000
PASS_DIFF_MEAN = 1.5
PASS_ORANGE_MAX = 4000
PASS_CYAN_MAX = 200
PASS_MEAN_LO, PASS_MEAN_HI = 20.0, 160.0

def near_control(aw_, ah_, area_):
    if aw_ == 0 or ah_ == 0:
        return False
    return (
        abs(aw_ - CTRL_AW) <= 30 and abs(ah_ - CTRL_AH) <= 30
    ) or area_ <= int(CTRL_AREA * 1.05)

active_pass = aw >= PASS_AW and ah >= PASS_AH and area >= PASS_AREA
diff_pass = diff_px >= PASS_DIFF_PX and diff_mean >= PASS_DIFF_MEAN
content = PASS_MEAN_LO <= mean <= PASS_MEAN_HI and std >= 18.0
cyan_idle = cyan >= 2000
orange_chevron = orange > PASS_ORANGE_MAX
orange_ok = orange <= PASS_ORANGE_MAX
cyan_ok = cyan <= PASS_CYAN_MAX

if ns0 and ns1:
    verdict = "E_NOSIGNAL"
elif (not ns0) and ns1:
    verdict = "B1_ONE_SHOT_THEN_DEAD"
elif ns0 and (not ns1):
    verdict = "E_NOSIGNAL_RECOVER"
elif ns1:
    verdict = "E_NOSIGNAL"
elif cyan_idle and orange >= 500:
    verdict = "B3_IDLE"
elif cyan_idle:
    verdict = "D1_CYAN_WRONG_STATE"
elif active_pass and cyan_ok and orange_ok and content and diff_pass:
    verdict = "A_FABRIC_PLAY_OK"
elif active_pass and cyan_ok and orange_ok and content and not diff_pass:
    verdict = "B2_STATIC_FULL_RASTER"
elif content and near_control(aw, ah, area) and cyan_ok:
    verdict = "C1_ARM_LETTERBOX"
elif orange_chevron and cyan_ok and near_control(aw, ah, area):
    verdict = "CONTROL_ARM_IDLE"
elif content and cyan_ok and (not active_pass) and ah >= PASS_AH and aw < PASS_AW:
    verdict = "D3_PILLAR"
elif content and cyan_ok and not active_pass:
    verdict = "D2_UPSCALE_GEOM"
else:
    verdict = "UNSCORED"

print(
    f"T0={a['path']} T1={b['path']}\n"
    f"ACTIVE0={a['aw']}x{a['ah']} ACTIVE1={aw}x{ah} AREA1={area} "
    f"ACTIVE_X1=[{b['ax0']},{b['ax1']}]\n"
    f"MEAN0={a['mean']:.1f} STD0={a['std']:.1f} MEAN1={mean:.1f} STD1={std:.1f}\n"
    f"ORANGE1={orange} CYAN1={cyan} MAGENTA1={magenta}\n"
    f"DIFF_MEAN={diff_mean:.3f} DIFF_PX={diff_px}\n"
    f"NOSIGNAL0={int(ns0)} NOSIGNAL1={int(ns1)}\n"
    f"GATES active_pass={int(active_pass)} diff_pass={int(diff_pass)} "
    f"content={int(content)} cyan_ok={int(cyan_ok)} orange_ok={int(orange_ok)}\n"
    f"VERDICT={verdict}"
)
sys.exit(0)
PY
