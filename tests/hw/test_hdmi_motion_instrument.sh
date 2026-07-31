#!/usr/bin/env bash
# test_hdmi_motion_instrument.sh — host-side validation of the HDMI motion instrument.
#
# Does NOT touch the device, /dev/video0, or SSH. Validates tools/hdmi_motion_instrument.py
# against parent-captured PNG bursts already on the lab host, plus a constructed FREEZE
# negative (one real frame duplicated N times).
#
# RED-before-GREEN contract:
#   known-good bursts → MOTION_OK      (rc=0)
#   duplicated-frame  → FREEZE         (rc=1)
#   green/chroma cast → COLOR_FAIL     (rc=2)  — hard FAIL even with decodes=0
#   vertical-dup/wrap → STRUCTURE_FAIL (rc=3)  — hard FAIL independent of motion
#   wrong rate/revisit→ RATE_FAIL      (rc=4)  — advances but not at source rate
#   empty/idle/no OCR → UNSCORED       (rc=77) — never a pass; never a measured failure
#
# Severity: STRUCTURE > COLOR > RATE > FREEZE > MOTION_OK > UNSCORED.
# Any positively-detected failure outranks UNSCORED and is never rc=77.
# rc=77 stays meaningful: idle screensaver / pre-play with nothing to read.
#
# Controlled pair + shipping corpus (parent hardware):
#   CAP480A_DIR broken 480p identity_skip desync → hard FAIL (rc=2 or 3)
#   CAP480B_DIR corrected 480p                     → MOTION_OK (rc=0)
#   CAP240FS_DIR known-good 240p                   → MOTION_OK (rc=0)
#   CAP480Q_DIR correct native 480p (counter 170→286) → MOTION_OK (rc=0)
#   CAP480N_DIR idle screensaver (no counter)      → UNSCORED (rc=77)
#
# Usage:
#   ./tests/hw/test_hdmi_motion_instrument.sh
#   LONG_DIR=/path/to/f_*.png ./tests/hw/test_hdmi_motion_instrument.sh
#   GOOD_240P_DIR=... GREEN_CAST_DIR=... CAP480A_DIR=... CAP480B_DIR=...
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/hdmi_motion_instrument.py"
# shellcheck source=tests/hw/hw_gate_common.sh
source "$ROOT/tests/hw/hw_gate_common.sh"

RC_PASS=0
RC_FAIL=1
RC_UNSCORED="${HW_RC_UNSCORED:-77}"

LONG_DIR="${LONG_DIR:-/tmp/long}"
RK3_FRAME="${RK3_FRAME:-/tmp/rk3_1/f_038.png}"
SOAK_DIRS="${SOAK_DIRS:-/tmp/soak1 /tmp/soak2 /tmp/soak3 /tmp/soak4}"
CC_DIRS="${CC_DIRS:-/tmp/cc1 /tmp/cc2 /tmp/cc3}"
# Parent hardware captures (known-good 240p / broken native-480p full green).
# Override if paths move; empty string disables.
GOOD_240P_DIR="${GOOD_240P_DIR:-/tmp/p240v}"
GREEN_CAST_DIR="${GREEN_CAST_DIR:-/tmp/p480}"
# Controlled pair: broken 480p desync vs corrected 480p vs good 240p.
CAP480A_DIR="${CAP480A_DIR:-/tmp/cap480a}"
CAP480B_DIR="${CAP480B_DIR:-/tmp/cap480b}"
CAP240FS_DIR="${CAP240FS_DIR:-/tmp/cap240fs}"
CAP480Q_DIR="${CAP480Q_DIR:-/tmp/cap480q}"
CAP480N_DIR="${CAP480N_DIR:-/tmp/cap480n}"

# Scratch under the repo (agent rule: never write /tmp for our own artifacts).
WORK="$ROOT/.agent-work/hdmi-motion-instrument-$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
skip=0

run_case() {
  local name="$1" expect_rc="$2"
  shift 2
  local out rc
  set +e
  out="$("$TOOL" "$@" 2>&1)"
  rc=$?
  set -e
  # true rc captured directly (never through a pipe).
  echo "CASE $name expect_rc=$expect_rc true_rc=$rc"
  echo "$out" | tail -n 8 | sed 's/^/  | /'
  if [[ "$rc" -eq "$expect_rc" ]]; then
    echo "  PASS $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name expect_rc=$expect_rc true_rc=$rc"
    fail=$((fail + 1))
  fi
}

echo "=== hdmi_motion_instrument host validation ==="
echo "TOOL=$TOOL"
echo "ROOT=$ROOT"

# 0. self-test (no capture data)
run_case "self-test" 0 --self-test

# 1. known-good long RK3 burst (parent: counter advances 216→264 within session)
if [[ -d "$LONG_DIR" ]] && compgen -G "$LONG_DIR/f_*.png" >/dev/null; then
  n_png=$(find "$LONG_DIR" -maxdepth 1 -name 'f_*.png' | wc -l)
  echo "LONG_DIR=$LONG_DIR n_png=$n_png"
  run_case "long-MOTION_OK" 0 "$LONG_DIR"
else
  echo "SKIP long: $LONG_DIR missing"
  skip=$((skip + 1))
fi

# 2. single bright frame with visible TREK24 counter (parent: n=336).
# Flash frames are the hard case: yellow on white. We require the overlay to be
# detected and, when decoded, the counter to be in the parent-observed band.
# A pure undecoded flash with overlay_present is NOT scored as FREEZE (the whole
# point of this instrument) — that is checked via --json, not a hard rc=0.
if [[ -f "$RK3_FRAME" ]]; then
  set +e
  one_json="$("$TOOL" --one --json "$RK3_FRAME" 2>&1)"
  one_rc=$?
  set -e
  echo "CASE rk3-f038-overlay expect=overlay_present true_rc=$one_rc"
  echo "  | $one_json" | head -c 500; echo
  # Extract fields without requiring jq.
  if printf '%s' "$one_json" | grep -q '"overlay_present": true\|"fp": "[a-f0-9]'; then
    n_val=$(printf '%s' "$one_json" | sed -n 's/.*"n": \([0-9]*\).*/\1/p' | head -1)
    if [[ -n "$n_val" ]]; then
      # Parent hand-read n=336. Accept exact or template-near (±2) with evidence.
      if [[ "$n_val" -ge 334 && "$n_val" -le 338 ]]; then
        echo "  PASS rk3-f038-overlay n=$n_val (parent band 334-338 around 336)"
        pass=$((pass + 1))
      else
        echo "  FAIL rk3-f038-overlay decoded n=$n_val outside parent band around 336"
        fail=$((fail + 1))
      fi
    else
      # Overlay seen, counter not decoded: honest UNSCORED for the number, but
      # the instrument correctly refused to invent a freeze from a flash frame.
      echo "  PASS rk3-f038-overlay overlay_present undecoded (flash OCR best-effort; not FREEZE)"
      pass=$((pass + 1))
    fi
  else
    echo "  FAIL rk3-f038-overlay: yellow overlay not detected"
    fail=$((fail + 1))
  fi
else
  echo "SKIP rk3 frame: $RK3_FRAME missing"
  skip=$((skip + 1))
fi

# 3. soak / cc known-good dirs (any present)
for d in $SOAK_DIRS $CC_DIRS; do
  if [[ -d "$d" ]] && compgen -G "$d/f_*.png" >/dev/null; then
    run_case "$(basename "$d")-MOTION_OK" 0 "$d"
  else
    echo "SKIP missing $d"
    skip=$((skip + 1))
  fi
done

# 4. GENUINE FREEZE negative: duplicate one real decoded frame N times
FREEZE_SRC=""
for cand in "$LONG_DIR/f_050.png" "$LONG_DIR/f_030.png" /tmp/soak1/f_030.png /tmp/cc1/f_030.png; do
  if [[ -f "$cand" ]]; then
    FREEZE_SRC=$cand
    break
  fi
done
if [[ -n "$FREEZE_SRC" ]]; then
  FDIR="$WORK/freeze_dup"
  mkdir -p "$FDIR"
  # 20 copies — enough for min_reads after any warmup logic; all identical pixels.
  for i in $(seq -w 1 20); do
    cp -f "$FREEZE_SRC" "$FDIR/f_${i}.png"
  done
  echo "FREEZE_SRC=$FREEZE_SRC n=20"
  run_case "dup-frame-FREEZE" 1 "$FDIR"
else
  echo "SKIP freeze negative: no source frame"
  skip=$((skip + 1))
fi

# 5. UNSCORED: empty dir must not pass
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
set +e
out="$("$TOOL" "$EMPTY" 2>&1)"
rc=$?
set -e
echo "CASE empty-UNSCORED expect_rc=77 true_rc=$rc"
echo "$out" | tail -n 3 | sed 's/^/  | /'
if [[ "$rc" -eq 77 ]]; then
  echo "  PASS empty-UNSCORED"
  pass=$((pass + 1))
else
  echo "  FAIL empty-UNSCORED true_rc=$rc"
  fail=$((fail + 1))
fi

# 6. COLOR_FAIL hard path — synthetic full-green field (parent 480p class).
#    decodes=0 is expected (no yellow overlay); must still be rc=2, NOT 77.
GDIR="$WORK/green_cast_synth"
mkdir -p "$GDIR"
python3 - <<'PY' "$GDIR"
import sys
from pathlib import Path
import numpy as np
from PIL import Image
out = Path(sys.argv[1])
# mean_rgb ~41.7, green_frac=1.0 → green_cast True (U,V~0 full-green class)
arr = np.zeros((180, 320, 3), dtype=np.uint8)
arr[:, :] = (20, 90, 15)
for i in range(12):
    Image.fromarray(arr).save(out / f"f_{i:03d}.png")
PY
run_case "synth-green-COLOR_FAIL" 2 "$GDIR"

# 7. FREEZE + green-cast → COLOR_FAIL wins (rc=2); colour outranks freeze.
FGDIR="$WORK/freeze_green_synth"
mkdir -p "$FGDIR"
python3 - <<'PY' "$FGDIR"
import sys
from pathlib import Path
import numpy as np
from PIL import Image
out = Path(sys.argv[1])
arr = np.zeros((180, 320, 3), dtype=np.uint8)
arr[:, :] = (25, 88, 18)
for i in range(12):
    Image.fromarray(arr).save(out / f"f_{i:03d}.png")
PY
run_case "synth-freeze-green-COLOR_FAIL" 2 "$FGDIR"

# 8. Optional parent hardware dirs (if provided / present)
if [[ -n "$GOOD_240P_DIR" && -d "$GOOD_240P_DIR" ]] && compgen -G "$GOOD_240P_DIR/f_*.png" >/dev/null; then
  run_case "parent-good-240p-MOTION_OK" 0 "$GOOD_240P_DIR"
else
  echo "SKIP parent-good-240p (set GOOD_240P_DIR=... to include)"
  skip=$((skip + 1))
fi
if [[ -n "$GREEN_CAST_DIR" && -d "$GREEN_CAST_DIR" ]] && compgen -G "$GREEN_CAST_DIR/f_*.png" >/dev/null; then
  # Full-green 480p may be COLOR_FAIL (rc=2) or STRUCTURE_FAIL (rc=3) if
  # desync structure is also present — both are hard fails; never 77/0.
  set +e
  out_gc="$("$TOOL" "$GREEN_CAST_DIR" 2>&1)"
  rc_gc=$?
  set -e
  echo "CASE parent-green-cast-HARD_FAIL expect_rc=2|3 true_rc=$rc_gc"
  echo "$out_gc" | tail -n 8 | sed 's/^/  | /'
  if [[ "$rc_gc" -eq 2 || "$rc_gc" -eq 3 ]]; then
    echo "  PASS parent-green-cast-HARD_FAIL"
    pass=$((pass + 1))
  else
    echo "  FAIL parent-green-cast-HARD_FAIL true_rc=$rc_gc (want 2 or 3)"
    fail=$((fail + 1))
  fi
else
  echo "SKIP parent-green-cast (set GREEN_CAST_DIR=... to include)"
  skip=$((skip + 1))
fi

# 9. Controlled pair — parent 480p desync RED/GREEN + good 240p.
#    Broken must hard-fail (structure and/or colour); corrected must PASS.
if [[ -n "$CAP480A_DIR" && -d "$CAP480A_DIR" ]] && compgen -G "$CAP480A_DIR/f_*.png" >/dev/null; then
  set +e
  out_a="$("$TOOL" "$CAP480A_DIR" 2>&1)"
  rc_a=$?
  set -e
  echo "CASE cap480a-desync-HARD_FAIL expect_rc=2|3 true_rc=$rc_a"
  echo "$out_a" | tail -n 10 | sed 's/^/  | /'
  if [[ "$rc_a" -eq 2 || "$rc_a" -eq 3 ]]; then
    echo "  PASS cap480a-desync-HARD_FAIL"
    pass=$((pass + 1))
  else
    echo "  FAIL cap480a-desync-HARD_FAIL true_rc=$rc_a (want 2 or 3, never 0/77)"
    fail=$((fail + 1))
  fi
else
  echo "SKIP cap480a (set CAP480A_DIR=... to include)"
  skip=$((skip + 1))
fi
if [[ -n "$CAP480B_DIR" && -d "$CAP480B_DIR" ]] && compgen -G "$CAP480B_DIR/f_*.png" >/dev/null; then
  run_case "cap480b-corrected-MOTION_OK" 0 "$CAP480B_DIR"
else
  echo "SKIP cap480b (set CAP480B_DIR=... to include)"
  skip=$((skip + 1))
fi
if [[ -n "$CAP240FS_DIR" && -d "$CAP240FS_DIR" ]] && compgen -G "$CAP240FS_DIR/f_*.png" >/dev/null; then
  run_case "cap240fs-good-MOTION_OK" 0 "$CAP240FS_DIR"
else
  echo "SKIP cap240fs (set CAP240FS_DIR=... to include)"
  skip=$((skip + 1))
fi
if [[ -n "$CAP480Q_DIR" && -d "$CAP480Q_DIR" ]] && compgen -G "$CAP480Q_DIR/f_*.png" >/dev/null; then
  run_case "cap480q-native480-MOTION_OK" 0 "$CAP480Q_DIR"
else
  echo "SKIP cap480q (set CAP480Q_DIR=... to include)"
  skip=$((skip + 1))
fi
if [[ -n "$CAP480N_DIR" && -d "$CAP480N_DIR" ]] && compgen -G "$CAP480N_DIR/f_*.png" >/dev/null; then
  # Idle screensaver: no burned-in counter. UNSCORED is correct — not a pass.
  run_case "cap480n-idle-UNSCORED" 77 "$CAP480N_DIR"
else
  echo "SKIP cap480n (set CAP480N_DIR=... to include)"
  skip=$((skip + 1))
fi

# 10. Synth magenta cast → COLOR_FAIL (generalised chroma, not green-only).
MDIR="$WORK/magenta_cast_synth"
mkdir -p "$MDIR"
python3 - <<'PY' "$MDIR"
import sys
from pathlib import Path
import numpy as np
from PIL import Image
out = Path(sys.argv[1])
arr = np.zeros((180, 320, 3), dtype=np.uint8)
arr[:, :] = (210, 40, 240)  # magenta; channel_spread ~200
for i in range(12):
    Image.fromarray(arr).save(out / f"f_{i:03d}.png")
PY
run_case "synth-magenta-COLOR_FAIL" 2 "$MDIR"

# 11. Synth horizontal wrap → STRUCTURE_FAIL rc=3.
WDIR="$WORK/wrap_synth"
mkdir -p "$WDIR"
python3 - <<'PY' "$WDIR"
import sys
from pathlib import Path
import numpy as np
from PIL import Image
out = Path(sys.argv[1])
arr = np.zeros((180, 320, 3), dtype=np.uint8)
for x in range(0, 30, 3):
    arr[:, x] = (220, 40, 40)
for x in range(290, 320, 3):
    arr[:, x] = (40, 40, 220)
for i in range(12):
    Image.fromarray(arr).save(out / f"f_{i:03d}.png")
PY
run_case "synth-wrap-STRUCTURE_FAIL" 3 "$WDIR"

# 12. Rate unit checks via analyze_counter_rate (no device).
python3 - <<PY
import sys
sys.path.insert(0, "$ROOT/tools")
from hdmi_motion_instrument import analyze_counter_rate

def expect(name, cond, detail):
    if cond:
        print(f"CASE rate-unit-{name} PASS")
        return 0
    print(f"CASE rate-unit-{name} FAIL {detail}")
    return 1

fail = 0
# good 24/30
ns=[]; n=200
for i in range(60):
    if i>0 and i%5!=0: n+=1
    ns.append(n)
ri=analyze_counter_rate(list(enumerate(ns)), source_fps=24.0, capture_fps=30.0)
fail += expect("good24on30", ri["rate"]=="RATE_OK" and ri["non_adjacent_revisits"]==0, ri)

# slow crawl
ns=[]; n=100
for i in range(60):
    if i>0 and i%4==0: n+=1
    ns.append(n)
ri=analyze_counter_rate(list(enumerate(ns)), source_fps=24.0, capture_fps=30.0)
fail += expect("slow-crawl", ri["rate_fail"] is True, ri)

# 4x race
ri=analyze_counter_rate([(i, 100+i*4) for i in range(60)], source_fps=24.0, capture_fps=30.0)
fail += expect("fast-4x", ri["rate_fail"] is True and ri["span_rate"]>1.5, ri)

# ping-pong revisits
ping=[100+(i%2) for i in range(60)]
ri=analyze_counter_rate(list(enumerate(ping)), source_fps=24.0, capture_fps=30.0)
fail += expect("pingpong-revisit", ri["revisit_fail"] is True and ri["non_adjacent_revisits"]>=2, ri)

sys.exit(1 if fail else 0)
PY
rate_rc=$?
echo "CASE rate-unit-block expect_rc=0 true_rc=$rate_rc"
if [[ "$rate_rc" -eq 0 ]]; then
  echo "  PASS rate-unit-block"
  pass=$((pass + 1))
else
  echo "  FAIL rate-unit-block"
  fail=$((fail + 1))
fi

echo "=== SUMMARY pass=$pass fail=$fail skip=$skip ==="
if [[ "$fail" -gt 0 ]]; then
  echo "RESULT=FAIL"
  exit "$RC_FAIL"
fi
if [[ "$pass" -eq 0 ]]; then
  echo "RESULT=UNSCORED (no cases ran)"
  exit "$RC_UNSCORED"
fi
echo "RESULT=PASS"
exit "$RC_PASS"
