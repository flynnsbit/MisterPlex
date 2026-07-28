#!/usr/bin/env bash
# Red-checks for the screensaver evidence chain.
#
# Two things must hold for tests/hw/test_osd_screensaver_selects.sh to mean
# anything:
#   1. The motion metric must read the real OSD_CONTROL=0 captures as STATIC and
#      the real OSD_CONTROL=1 captures as MOVING. Both sets had Screensaver
#      selected, so this is the whole defect, measured.
#   2. The metric must not be frame difference. Every frame in the static set
#      differs from its neighbours because the core boils the left edge, so a
#      difference-based gate would call the broken case working.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOTION="$ROOT/scripts/idle_motion_probe.py"
FIX="$ROOT/tests/fixtures/hw_visual/screensaver_osd_control"
CARD="$ROOT/tests/hw/test_osd_screensaver_selects.sh"
MAIN="$ROOT/arm/misterplexd/main.cpp"
FAILED=0

echo "Scope: grades the committed real HDMI captures from the OSD_CONTROL=0 and OSD_CONTROL=1 runs and checks the screensaver card's safety caps and the daemon's OSD_CONTROL warning. It does NOT contact a MiSTer and proves nothing about the device's present state."

check() {
    local name="$1" want_rc="$2"
    shift 2
    "$@" >"$ROOT/build/screensaver_logic_$name.log" 2>&1
    local rc=$?
    if [ "$rc" = "$want_rc" ]; then
        echo "OK $name (rc=$rc): $(grep -oE 'verdict=[A-Z_]+ travel=[0-9.]+' "$ROOT/build/screensaver_logic_$name.log" | tail -1)"
    else
        echo "FAIL $name rc=$rc want=$want_rc"
        tail -5 "$ROOT/build/screensaver_logic_$name.log"
        FAILED=1
    fi
}

mkdir -p "$ROOT/build"

python3 "$MOTION" --self-test >"$ROOT/build/screensaver_logic_selftest.log" 2>&1
if [ $? -eq 0 ]; then
    echo "OK motion probe self-test (static/moving/black/uniform separated)"
else
    echo "FAIL motion probe self-test"
    cat "$ROOT/build/screensaver_logic_selftest.log"
    FAILED=1
fi

if [ ! -d "$FIX/red_osd_control_0" ] || [ ! -d "$FIX/green_osd_control_1" ]; then
    echo "FAIL missing committed captures under $FIX"
    exit 1
fi

# 1. The defect, measured: same OSD selection, opposite outcomes.
check red_is_static 1 python3 "$MOTION" "$FIX"/red_osd_control_0/*.png --expect moving
check green_is_moving 0 python3 "$MOTION" "$FIX"/green_osd_control_1/*.png --expect moving
check red_static_confirmed 0 python3 "$MOTION" "$FIX"/red_osd_control_0/*.png --expect static

# 2. A frame-difference gate would have passed the broken case. Prove the
#    frames really do differ, so the point is not hypothetical.
DIFF="$(python3 - "$FIX/red_osd_control_0" <<'PY'
import sys, glob
import numpy as np
from PIL import Image
paths = sorted(glob.glob(sys.argv[1] + "/*.png"))
frames = [np.asarray(Image.open(p).convert("L"), dtype=np.int16) for p in paths]
# The damage lives in the left band; report that and the whole frame, because a
# naive gate would trip on either.
band = slice(0, 200)
worst_band = max(float((np.abs(frames[i][:, band] - frames[i + 1][:, band]) > 16).mean())
                 for i in range(len(frames) - 1))
worst_full = max(float((np.abs(frames[i] - frames[i + 1]) > 16).mean())
                 for i in range(len(frames) - 1))
print(f"{worst_band:.4f} {worst_full:.4f}")
PY
)"
BAND_DIFF="${DIFF%% *}"
FULL_DIFF="${DIFF##* }"
if python3 -c "import sys; sys.exit(0 if float('$BAND_DIFF') > 0.05 else 1)"; then
    echo "OK static captures still boil frame to frame (left band ${BAND_DIFF}, whole frame ${FULL_DIFF} of pixels) — a frame-difference gate would have called this motion"
else
    echo "FAIL static captures differ by only $BAND_DIFF in the left band; the anti-frame-difference argument is unproven"
    FAILED=1
fi

# 3. The card must keep its thrash caps. Exceeding them once cost a device.
for var in SCREENSAVER_HOLD_WRITES=99 SCREENSAVER_HOLD_INTERVAL=0.05; do
    out="$(env "$var" bash "$CARD" 2>&1 | tail -1)"
    rc_line="$out"
    if printf '%s' "$rc_line" | grep -q 'SCREENSAVER_RESULT=UNSCORED'; then
        echo "OK card refuses $var"
    else
        echo "FAIL card accepted $var: $rc_line"
        FAILED=1
    fi
done

# 4. The card must never turn an unreachable device into a pass.
if grep -q 'reason=daemon-not-running-or-host-unreachable' "$CARD"; then
    echo "OK card treats an unreachable device as UNSCORED"
else
    echo "FAIL card has no unreachable-device guard"
    FAILED=1
fi

# 5. The daemon must say what OSD_CONTROL=0 costs.
if grep -q 'WARNING OSD_CONTROL=0 disables the OSD poll thread' "$MAIN"; then
    echo "OK misterplexd warns that OSD_CONTROL=0 kills the whole OSD path"
else
    echo "FAIL misterplexd does not warn about OSD_CONTROL=0"
    FAILED=1
fi

# 6. Source invariants for three ways this card was observed to report the
#    wrong thing on real hardware. Each of these was a live run, not a review
#    comment, so each gets a standing check that the fix has not been undone.

# 6a. A backgrounded child of an ssh command is torn down when the session
#     closes. The card used to launch the hold loop with a bare "&", check
#     ssh's exit status, get 0, and grade a screen nobody had asked to change.
if grep -q 'setsid sh -c' "$CARD"; then
    echo "OK hold loop is detached with setsid, not a bare ssh background job"
else
    echo "FAIL hold loop can be torn down when the ssh session closes"
    FAILED=1
fi

# 6b. Launching is not evidence. The only proof the selection reached the
#     fabric is the OSD word read back out of PLXS.
if grep -q 'reason=selection-never-reached-osd-word' "$CARD" && \
   grep -q 'OSD_WORD_OBSERVED' "$CARD"; then
    echo "OK card reads the OSD word back out of PLXS before grading pixels"
else
    echo "FAIL card does not verify the selection reached the OSD word"
    FAILED=1
fi

# 6c. The daemon log is corroboration, not a measurement, and it is lossy
#     because the daemon logs on change. An empty log once overrode a measured
#     30.8px of centroid travel and produced UNSCORED for a working screensaver.
#     Motion must be decided before the log is consulted.
if python3 - "$CARD" <<'PY'
import sys
text = open(sys.argv[1]).read()
pass_at = text.find('SCREENSAVER_RESULT=PASS')
silent_at = text.find('reason=static-picture-and-silent-log')
never_at = text.find('reason=daemon-did-not-apply-selection')
if pass_at < 0 or silent_at < 0 or never_at < 0:
    sys.exit(1)
# The PASS branch must come before every log-based verdict.
sys.exit(0 if pass_at < silent_at and pass_at < never_at else 1)
PY
then
    echo "OK measured motion is decided before the daemon log is consulted"
else
    echo "FAIL a log-based verdict can pre-empt a measured moving picture"
    FAILED=1
fi

# 6d. The log window must not be established by writing a marker into a file
#     the daemon holds open: the daemon keeps writing at its own offset and the
#     marker is stranded, so the card reads an empty window and blames the OSD
#     poll thread for a daemon that was working correctly.
if grep -q 'MARK ' "$CARD"; then
    echo "FAIL card still marks the daemon log by writing into it"
    FAILED=1
else
    echo "OK log window is a read-only byte offset, not an injected marker"
fi

# 6e. The log path must be resolved from the daemon's own stdout, not assumed.
if grep -q '/proc/\$p/fd/1' "$CARD" && grep -q 'reason=daemon-log-unresolvable' "$CARD"; then
    echo "OK daemon log path is resolved from the running process, and refused if unknown"
else
    echo "FAIL card assumes a hardcoded daemon log path"
    FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
    echo "SCREENSAVER_LOGIC_RESULT=PASS"
    exit 0
fi
echo "SCREENSAVER_LOGIC_RESULT=FAIL"
exit 1
