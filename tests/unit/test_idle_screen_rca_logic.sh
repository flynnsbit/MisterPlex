#!/usr/bin/env bash
# Red-checks for tests/hw/test_idle_screen_pixel_rca.sh.
#
# The RCA card names one of five causes for a black or damaged idle screen. A
# card that always names the same one is worthless, and a card that can exit 0
# without grading pixels is worse. This drives every branch from fixtures and
# asserts both the verdict and the exit code, including that the only PASS
# branch really does require clean pixels.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$ROOT/tests/hw/test_idle_screen_pixel_rca.sh"
INTEG="$ROOT/scripts/idle_frame_integrity.py"
WORK="$ROOT/build/idle_rca_logic"
FAILED=0

echo "Scope: exercises the RCA card's decision logic against synthetic mailbox and frame fixtures. Every branch is asserted on both verdict and exit code. It does NOT contact a MiSTer, does not capture HDMI, and therefore proves nothing about the device's current state — tests/hw/test_idle_screen_pixel_rca.sh owns that."

rm -rf "$WORK"
mkdir -p "$WORK"

python3 "$INTEG" --emit-synthetic clean  --emit-path "$WORK/clean.png"  >/dev/null
python3 "$INTEG" --emit-synthetic ragged --emit-path "$WORK/ragged.png" >/dev/null
python3 "$INTEG" --emit-synthetic black  --emit-path "$WORK/black.png"  >/dev/null
# A second ragged frame that differs, so instability is real rather than a copy.
python3 - "$WORK/ragged.png" "$WORK/ragged2.png" <<'PY'
import sys
import numpy as np
from PIL import Image
src = np.asarray(Image.open(sys.argv[1]).convert("L"))
rng = np.random.default_rng(7)
out = src.copy()
for y in range(40, out.shape[0] - 40):
    eaten = int(rng.integers(0, 190))
    out[y, 22 : 22 + eaten] = 0
Image.fromarray(out, mode="L").convert("RGB").save(sys.argv[2])
PY

# plxd upper word: [1:0] free mask, [2] disp bank, [3] swap pending
mkprobe() {
    local path="$1" plxk_hi="$2" plxd_hi="$3" luma="$4"
    cat >"$path" <<EOF
PLXK_LO=0x504C584B
PLXK_HI=$plxk_hi
PLXS_LO=0x504C5853
PLXS_HI=0xF2434000
PLXF_LO=0x504C5846
PLXF_HI=0xFFFF1086
PLXD_LO=0x504C5844
PLXD_HI=$plxd_hi
BANK0_Y= $luma $luma $luma $luma $luma
BANK0_U=0x82828282
BANK0_V=0x7E7E7E7E
BANK1_Y= $luma $luma $luma $luma $luma
BANK1_U=0x82828282
BANK1_V=0x7E7E7E7E
DAEMON_PID=1234
CORENAME=Plex
RBF_MD5=fixturefixturefixturefixturefixt
EOF
}

CONTENT=0x2D2D2D2D
BLACKY=0x10101010
SWAP_OK=0x9A9E0002     # vsync=0x9A9E disp_bank=0 swap_pending=0 free=0b10
SWAP_STUCK=0x9A9E0008  # vsync=0x9A9E disp_bank=0 swap_pending=1 free=0b00
# Probe L is the scanout-liveness resample: same state, vsync advanced. The card
# requires the bank vsync counter to move, because a core that is loaded but
# held in reset publishes its mailbox magics once and then freezes, and a frozen
# core in front of a static screen grades CLEAN.
SWAP_OK_L=0x9A9F0002   # vsync advanced by 1
SWAP_STUCK_L=0x9A9F0008

run_case() {
    local name="$1" want_verdict="$2" want_rc="$3"
    shift 3
    local log="$WORK/$name.log"
    env "$@" IDLE_RCA_OUT="$WORK/$name" IDLE_RCA_SETTLE=0 \
        bash "$CARD" >"$log" 2>&1
    local rc=$?
    local got
    got="$(grep -oE '^IDLE_RCA_VERDICT=[A-Z_]+' "$log" | tail -1 | cut -d= -f2)"
    local got_result
    got_result="$(grep -oE '^IDLE_RCA_RESULT=[A-Z_]+' "$log" | tail -1 | cut -d= -f2)"
    if [ "$rc" = "$want_rc" ] && { [ -z "$want_verdict" ] || [ "$got" = "$want_verdict" ]; }; then
        echo "OK $name -> verdict=${got:-$got_result} rc=$rc"
    else
        echo "FAIL $name -> verdict=${got:-none} result=${got_result:-none} rc=$rc (want verdict=${want_verdict:-any} rc=$want_rc)"
        sed -n '2,12p' "$log"
        FAILED=1
    fi
}

mkprobe "$WORK/p_notdrawn.txt"  0x200097D5 "$SWAP_OK"    "$BLACKY"
mkprobe "$WORK/p_stuck.txt"     0x200097D5 "$SWAP_STUCK" "$CONTENT"
mkprobe "$WORK/p_ok_a.txt"      0x200097D5 "$SWAP_OK"    "$CONTENT"
mkprobe "$WORK/p_ok_b.txt"      0x200097D5 "$SWAP_OK"    "$CONTENT"
mkprobe "$WORK/p_ring_b.txt"    0x200097E1 "$SWAP_OK"    "$CONTENT"
mkprobe "$WORK/p_live.txt"      0x200097D5 "$SWAP_OK_L"  "$CONTENT"
mkprobe "$WORK/p_live_stuck.txt" 0x200097D5 "$SWAP_STUCK_L" "$CONTENT"
sed 's/^PLXK_LO=.*/PLXK_LO=0xDEADBEEF/' "$WORK/p_ok_a.txt" >"$WORK/p_badmagic.txt"
# Plex fabric absent: the ARM daemon still publishes PLXK, but the FPGA-written
# PLXD/PLXF magics are gone. This is the real state a MiSTer sitting on the MENU
# core returns, and the card graded it PRESENTED_CLEAN until this case existed.
sed -e 's/^PLXD_LO=.*/PLXD_LO=0x00000000/' \
    -e 's/^PLXF_LO=.*/PLXF_LO=0x00000000/' \
    -e 's/^CORENAME=.*/CORENAME=MENU/' "$WORK/p_ok_a.txt" >"$WORK/p_nofabric.txt"

# 1. Nothing in the displayed bank.
run_case not_drawn NOT_DRAWN 1 \
    IDLE_RCA_PROBE_A="$WORK/p_notdrawn.txt" IDLE_RCA_PROBE_B="$WORK/p_notdrawn.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"

# 2. Frame present, swap wedged for a full sample interval.
run_case wedged DRAWN_NOT_PRESENTED 1 \
    IDLE_RCA_PROBE_A="$WORK/p_stuck.txt" IDLE_RCA_PROBE_B="$WORK/p_stuck.txt" IDLE_RCA_PROBE_L="$WORK/p_live_stuck.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"

# 3. Frame present and swapping, screen black.
run_case black_screen DRAWN_OVERWRITTEN 1 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/black.png" IDLE_RCA_CAP_B="$WORK/black.png"

# 4. Damaged pixels with the producer idle -> presentation path is at fault.
run_case corrupt_idle_producer PRESENTED_CORRUPT 1 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/ragged.png" IDLE_RCA_CAP_B="$WORK/ragged2.png"

# 5. Same damage, but the producer rang the doorbell in between: the ARM cannot
#    be excluded, so the verdict must change. This is what keeps branch 4 honest.
run_case corrupt_active_producer DRAWN_OVERWRITTEN 1 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ring_b.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/ragged.png" IDLE_RCA_CAP_B="$WORK/ragged2.png"

# 6. The only PASS branch.
run_case clean PRESENTED_CLEAN 0 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"

# 7. Wrong doorbell magic must be UNSCORED (77), never a verdict. This is the
#    stale-mailbox trap: 0x3007F1xx still answers with valid magics on a device
#    running the 0x80000-stride core.
run_case bad_magic "" 77 \
    IDLE_RCA_PROBE_A="$WORK/p_badmagic.txt" IDLE_RCA_PROBE_B="$WORK/p_badmagic.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"

# 8. The card must derive its window from the layout header, not a literal.
if grep -qE '0x3007F1[0-9A-Fa-f]{2}' "$CARD"; then
    echo "FAIL card hardcodes a 0x3007F1xx mailbox address"
    FAILED=1
else
    echo "OK card contains no hardcoded 0x3007F1xx mailbox address"
fi
if grep -q 'kPlex480pYuv420pDoorbellPhys' "$CARD"; then
    echo "OK card derives the doorbell from ddr_frame_layout.hpp"
else
    echo "FAIL card does not derive the doorbell from the layout header"
    FAILED=1
fi

# 9. The pass branch must depend on the frame grader, not merely on capture
#    succeeding. Feed the PASS fixture set but break the grader's budget so a
#    clean frame is rejected; the card must stop passing.
run_case clean_but_strict PRESENTED_CORRUPT 1 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png" \
    IDLE_RCA_INTEGRITY_ARGS="--max-spread -1"

# 10. No Plex fabric loaded. PLXK is written by misterplexd, so it is still
#     valid; only the FPGA-published PLXD/PLXF magics are gone. This is not a
#     hypothetical: run against a MiSTer sitting on the MENU core with the
#     daemon up, this card returned IDLE_RCA_RESULT=PASS verdict=PRESENTED_CLEAN.
#     It graded the menu screen, whose left edges are naturally clean, and DDR
#     had kept the previous core's frame bytes across the warm boot so even the
#     "is anything drawn" sample looked like a picture. Everything about that
#     run was green and none of it was about Plex.
run_case no_plex_fabric "" 77 \
    IDLE_RCA_PROBE_A="$WORK/p_nofabric.txt" IDLE_RCA_PROBE_B="$WORK/p_nofabric.txt" IDLE_RCA_PROBE_L="$WORK/p_live.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"
if grep -q 'reason=plex-fabric-not-loaded' "$WORK/no_plex_fabric.log"; then
    echo "OK no_plex_fabric names the missing FPGA-published magic"
else
    echo "FAIL no_plex_fabric did not name plex-fabric-not-loaded"
    FAILED=1
fi

# 11. Fabric loaded but not scanning out: magics present, bank vsync frozen.
#     A held-in-reset core in front of a static picture would otherwise grade
#     CLEAN, because nothing else this card reads has to change over time.
run_case scanout_frozen "" 77 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" IDLE_RCA_PROBE_L="$WORK/p_ok_a.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"
if grep -q 'reason=scanout-frozen' "$WORK/scanout_frozen.log"; then
    echo "OK scanout_frozen names the frozen bank vsync counter"
else
    echo "FAIL scanout_frozen did not name scanout-frozen"
    FAILED=1
fi

# 12. Fixture mode must be total. Supplying probe A and B but not probe L used
#     to make the card SSH to the device for the one probe nobody provided, so
#     this "hermetic" file silently depended on the state of a real MiSTer.
run_case fixture_mode_partial "" 77 \
    IDLE_RCA_PROBE_A="$WORK/p_ok_a.txt" IDLE_RCA_PROBE_B="$WORK/p_ok_b.txt" \
    IDLE_RCA_CAP_A="$WORK/clean.png" IDLE_RCA_CAP_B="$WORK/clean.png"
if grep -q 'reason=fixture-mode-missing-probe' "$WORK/fixture_mode_partial.log"; then
    echo "OK fixture_mode_partial refuses to answer a missing fixture from the device"
else
    echo "FAIL fixture_mode_partial did not refuse the live fallback"
    FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
    echo "IDLE_RCA_LOGIC_RESULT=PASS"
    exit 0
fi
echo "IDLE_RCA_LOGIC_RESULT=FAIL"
exit 1
