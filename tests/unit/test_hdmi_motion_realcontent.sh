#!/usr/bin/env bash
# test_hdmi_motion_realcontent.sh — real-title chroma + fixture-free motion.
#
# Observed defect (parent 2026-08-02, Big Buck Bunny rk9):
#   Correct 624x350 playback scored COLOR_FAIL rc=2 (chroma_cast_frames=17)
#   on saturated grass/sky — scene colour treated as desync cast.
#   motion=UNSCORED because TREK24 counter is absent on real titles.
#
# Physical fix (NOT threshold-raising on CHROMA_SPREAD_FAIL):
#   chroma_cast requires high channel_spread AND high cast_coherence
#   (uniform whole-frame cast). Content max coh≈0.78; desync fields≈1.0.
#   Motion: letterbox-excluded content_fp uniqueness (no TREK24 required).
#
# Fixtures (genuine device captures):
#   files/device-evidence/instrument_verdict/bbb9_unit/     MUST PASS rc=0
#   files/device-evidence/instrument_verdict/BBB_CORRECT.png single OK
#   files/device-evidence/instrument_verdict/BROKEN_desync_480p.png MUST FAIL 2/3
#   files/device-evidence/instrument_verdict/BROKEN_green.png MUST FAIL 2/3
#   IDLE_screen.png still IDLE; CORRECT.png still OK
#
# Pre-registered assertions (incl. negatives):
#   BBB burst → VERDICT=OK rc=0; chroma_cast_frames=0; motion=MOTION_OK;
#               content_unique_fp>=2; applied_matches>=1
#   BROKEN    → rc in {2,3}; GREEN or CHROMA or STRUCTURE; NOT OK
#   freeze of one BBB frame ×N → FREEZE rc=1 (content pin)
#   MUST NOT pass BBB by also passing BROKEN
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/hdmi_motion_instrument.py"
FIX="$ROOT/files/device-evidence/instrument_verdict"
FAILED=0
fail() { echo "FAIL $*"; FAILED=1; }

[ -f "$TOOL" ] || { echo "FAIL missing $TOOL"; exit 1; }
[ -d "$FIX/bbb9_unit" ] || { echo "FAIL missing $FIX/bbb9_unit"; exit 1; }
for f in BBB_CORRECT.png BROKEN_desync_480p.png BROKEN_green.png IDLE_screen.png CORRECT.png; do
  [ -f "$FIX/$f" ] || { echo "FAIL missing $FIX/$f"; exit 1; }
done

# --- BBB real-content burst: MUST PASS ---
out="$(python3 "$TOOL" --jobs 4 "$FIX/bbb9_unit" 2>/dev/null)"; rc=$?
echo "true rc_bbb=$rc"
echo "$out" | tail -5
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -q '^VERDICT=' || fail "bbb: missing VERDICT last line"
echo "$last" | grep -qE 'VERDICT=OK ' || fail "bbb: want VERDICT=OK got: $last"
[ "$rc" -eq 0 ] || fail "bbb: want rc=0 got $rc"
echo "$out" | grep -E 'chroma_cast_frames=0' || fail "bbb: want chroma_cast_frames=0"
echo "$out" | grep -E 'motion=MOTION_OK' || fail "bbb: want motion=MOTION_OK"
echo "$out" | grep -E 'content_motion=MOTION_OK' || fail "bbb: want content_motion=MOTION_OK"
echo "$out" | grep -E 'content_unique_fp=([2-9]|[1-9][0-9])' || fail "bbb: want content_unique_fp>=2"
echo "$last" | grep -q 'applied_matches=[1-9]' || fail "bbb: applied_matches must be >0"
echo "$last" | grep -qE 'GREEN_FIELD|COLOR_FAIL|IDLE_SCREEN' && fail "bbb: must not fail-class VERDICT" || true

# --- Single correct BBB frame ---
out="$(python3 "$TOOL" "$FIX/BBB_CORRECT.png" 2>/dev/null)"; rc=$?
echo "true rc_bbb1=$rc"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -qE 'VERDICT=OK ' || fail "bbb1: want VERDICT=OK got: $last"
[ "$rc" -eq 0 ] || fail "bbb1: want rc=0 got $rc"
echo "$out" | grep -E 'color=COLOR_OK|chroma_cast_frames=0' || true

# --- BROKEN desync MUST STILL FAIL ---
out="$(python3 "$TOOL" "$FIX/BROKEN_desync_480p.png" 2>/dev/null)"; rc=$?
echo "true rc_broken_desync=$rc"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last"
if [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then
  fail "broken_desync: want rc=2/3 got $rc"
fi
echo "$last" | grep -qE 'GREEN_FIELD|COLOR_FAIL|OVERLAY|STRUCTURE' || fail "broken_desync: want fail class"
echo "$last" | grep -qE 'VERDICT=OK ' && fail "broken_desync: must not OK" || true

out="$(python3 "$TOOL" "$FIX/BROKEN_green.png" 2>/dev/null)"; rc=$?
echo "true rc_broken_green=$rc"
if [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then
  fail "broken_green: want rc=2/3 got $rc"
fi

# --- Content FREEZE: duplicate one real frame ---
FZ="$ROOT/.agent-work/w-instr/freeze_bbb_$$"
mkdir -p "$FZ"
src="$FIX/bbb9_unit/f_028.png"
[ -f "$src" ] || src="$(ls "$FIX/bbb9_unit"/f_*.png | head -1)"
for i in $(seq -w 1 12); do cp "$src" "$FZ/f_${i}.png"; done
out="$(python3 "$TOOL" --jobs 2 "$FZ" 2>/dev/null)"; rc=$?
echo "true rc_freeze=$rc"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last"
echo "$out" | grep -E 'motion=FREEZE|content_motion=FREEZE' || fail "freeze: want FREEZE motion"
[ "$rc" -eq 1 ] || fail "freeze: want rc=1 got $rc"
rm -rf "$FZ"

# --- Regression: idle + trek correct still typed ---
out="$(python3 "$TOOL" "$FIX/IDLE_screen.png" 2>/dev/null)"; rc=$?
echo "true rc_idle=$rc"
echo "$out" | grep -E 'VERDICT=IDLE_SCREEN' || fail "idle: want IDLE_SCREEN"
[ "$rc" -ne 0 ] || fail "idle: rc=0 is false pass"

out="$(python3 "$TOOL" "$FIX/CORRECT.png" 2>/dev/null)"; rc=$?
echo "true rc_trek=$rc"
echo "$out" | grep -E 'VERDICT=OK ' || fail "trek: want OK"
[ "$rc" -eq 0 ] || fail "trek: want rc=0 got $rc"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED hdmi_motion_realcontent"
  exit 1
fi
echo "OK hdmi_motion_realcontent: BBB PASS + BROKEN FAIL + content FREEZE + idle/trek"
exit 0
