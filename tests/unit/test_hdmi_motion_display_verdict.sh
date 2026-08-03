#!/usr/bin/env bash
# test_hdmi_motion_display_verdict.sh — release-glass display VERDICT line.
#
# Observed defect (parent 2026-08-02): instrument exited rc=2 with no VERDICT=
# line (argparse --dir / bare usage), forcing eye-judgment of PNGs. Also single
# green-field frame returned UNSCORED instead of GREEN_FIELD; idle chevron was
# not named IDLE_SCREEN.
#
# Fixtures are genuine device captures (not synthetic):
#   files/device-evidence/instrument_verdict/BROKEN_green.png
#   files/device-evidence/instrument_verdict/CORRECT.png
#   files/device-evidence/instrument_verdict/IDLE_screen.png
#
# Pre-registered assertions (incl. negatives a naive tool would fail):
#   BROKEN  → VERDICT contains GREEN_FIELD; OVERLAY_DUPLICATED; rc in {2,3}; applied_matches>=1
#   CORRECT → VERDICT=OK; rc=0; must NOT say GREEN_FIELD or IDLE_SCREEN
#   IDLE    → VERDICT=IDLE_SCREEN; must NOT say OK as playback pass
#   --dir alias works; bad flag still prints VERDICT=
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/hdmi_motion_instrument.py"
FIX="$ROOT/files/device-evidence/instrument_verdict"
FAILED=0

fail() { echo "FAIL $*"; FAILED=1; }

[ -f "$TOOL" ] || { echo "FAIL missing $TOOL"; exit 1; }
for f in BROKEN_green.png CORRECT.png IDLE_screen.png; do
  [ -f "$FIX/$f" ] || { echo "FAIL missing fixture $FIX/$f"; exit 1; }
done

run_one() {
  local label="$1" path="$2"
  local out rc
  out="$(python3 "$TOOL" "$path" 2>/dev/null)"
  rc=$?
  # NOTE: rc captured from python directly (no pipe).
  printf '%s\n' "$out"
  echo "RC_$label=$rc"
  return "$rc"
}

# --- BROKEN ---
out="$(python3 "$TOOL" "$FIX/BROKEN_green.png" 2>/dev/null)"; rc=$?
echo "true rc_broken=$rc"
echo "$out" | tail -5
echo "$out" | grep -q '^VERDICT=' || fail "broken: missing VERDICT= line"
echo "$out" | grep -E '^VERDICT=' | grep -q 'GREEN_FIELD' || fail "broken: want GREEN_FIELD in VERDICT"
echo "$out" | grep -E '^VERDICT=' | grep -q 'OVERLAY_DUPLICATED' || fail "broken: want OVERLAY_DUPLICATED"
echo "$out" | grep -E '^VERDICT=' | grep -q 'applied_matches=[1-9]' || fail "broken: applied_matches must be >0"
if [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then
  fail "broken: want rc=2 (COLOR) or 3 (STRUCTURE), got $rc"
fi
# Negative: must not claim OK playback
echo "$out" | grep -E '^VERDICT=OK ' && fail "broken: must not VERDICT=OK" || true

# --- CORRECT ---
out="$(python3 "$TOOL" "$FIX/CORRECT.png" 2>/dev/null)"; rc=$?
echo "true rc_correct=$rc"
echo "$out" | tail -3
echo "$out" | grep -q '^VERDICT=' || fail "correct: missing VERDICT="
echo "$out" | grep -E '^VERDICT=' | grep -qE 'VERDICT=OK ' || fail "correct: want VERDICT=OK"
[ "$rc" -eq 0 ] || fail "correct: want rc=0 got $rc"
echo "$out" | grep -E '^VERDICT=' | grep -q 'GREEN_FIELD' && fail "correct: must not GREEN_FIELD" || true
echo "$out" | grep -E '^VERDICT=' | grep -q 'IDLE_SCREEN' && fail "correct: must not IDLE_SCREEN" || true
echo "$out" | grep -E '^VERDICT=' | grep -q 'OVERLAY_DUPLICATED' && fail "correct: must not OVERLAY_DUPLICATED" || true

# --- IDLE ---
out="$(python3 "$TOOL" "$FIX/IDLE_screen.png" 2>/dev/null)"; rc=$?
echo "true rc_idle=$rc"
echo "$out" | tail -3
echo "$out" | grep -E '^VERDICT=' | grep -q 'IDLE_SCREEN' || fail "idle: want IDLE_SCREEN"
echo "$out" | grep -E '^VERDICT=OK ' && fail "idle: must not VERDICT=OK" || true
# idle is not a pass
[ "$rc" -ne 0 ] || fail "idle: rc=0 would be a false playback pass"

# --- --dir alias (parent failure mode) ---
out="$(python3 "$TOOL" --dir "$FIX" 2>/dev/null | tail -1)"
# scoring whole dir may be mixed; just require VERDICT line exists when using --dir on single-file via dir of one
out="$(python3 "$TOOL" --dir "$FIX/broken_burst" 2>/dev/null)"; rc=$?
echo "true rc_dir=$rc"
echo "$out" | grep -q '^VERDICT=' || fail "--dir: missing VERDICT="
echo "$out" | grep -E '^VERDICT=' | grep -q 'GREEN_FIELD' || fail "--dir broken_burst: want GREEN_FIELD"

# --- argparse still emits VERDICT ---
out="$(python3 "$TOOL" --not-a-real-flag 2>/dev/null)"; rc=$?
echo "true rc_badarg=$rc"
echo "$out" | grep -q '^VERDICT=' || fail "badarg: missing VERDICT="
[ "$rc" -eq 2 ] || fail "badarg: want rc=2 got $rc"
# LAST line must be VERDICT=
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -q '^VERDICT=' || fail "badarg: last stdout line must be VERDICT= got: $last"

# --- missing path: was empty stdout rc=77 (parent gap) ---
out="$(python3 "$TOOL" /no/such/hdmi_path_xyz 2>/dev/null)"; rc=$?
echo "true rc_miss=$rc"
echo "$out" | tail -3
echo "$out" | grep -q '^VERDICT=' || fail "miss: missing VERDICT= line"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -q '^VERDICT=' || fail "miss: last line must be VERDICT= got: $last"
echo "$last" | grep -q 'path_not_found' || fail "miss: want path_not_found reason"
[ "$rc" -eq 77 ] || fail "miss: want rc=77 got $rc"
# 77 is never a pass — just typed
[ "$rc" -ne 0 ] || fail "miss: rc=0 would be false pass"

# --- CORRECT: VERDICT is last line + provenance-tagged src_fps ---
out="$(python3 "$TOOL" "$FIX/CORRECT.png" 2>/dev/null)"; rc=$?
echo "true rc_prov=$rc"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -q '^VERDICT=OK ' || fail "prov: last line want VERDICT=OK got: $last"
echo "$out" | grep -E 'src_fps=[0-9.]+ \(DEFAULT_ASSUMED\)|src_fps=[0-9.]+\(DEFAULT_ASSUMED\)' \
  || fail "prov: want src_fps=…(DEFAULT_ASSUMED) tagged numeric"
echo "$out" | grep -E 'src_fps=23\.976[^0-9]' && fail "prov: bare/forbidden 23.976 must not appear" || true
# reason must admit DEFAULT_ASSUMED when used
echo "$last" | grep -q 'DEFAULT_ASSUMED' || fail "prov: VERDICT reason must mention DEFAULT_ASSUMED when fps assumed"
# applied_matches printed
echo "$last" | grep -q 'applied_matches=[1-9]' || fail "prov: applied_matches>0 on CORRECT"

# --- self-test covers exception wrapper + format_prov ---
out="$(python3 "$TOOL" --self-test 2>/dev/null)"; rc=$?
echo "true rc_self=$rc"
echo "$out" | tail -3
[ "$rc" -eq 0 ] || fail "self-test: want rc=0 got $rc"
last="$(printf '%s\n' "$out" | awk 'NF{l=$0} END{print l}')"
echo "$last" | grep -q '^VERDICT=' || fail "self-test: last line must be VERDICT="

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED hdmi_motion_display_verdict"
  exit 1
fi
echo "OK hdmi_motion_display_verdict: GREEN_FIELD+OVERLAY_DUP / OK / IDLE + always-last VERDICT + provenance"
exit 0
