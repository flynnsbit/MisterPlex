#!/usr/bin/env bash
# analog_menu 1/2/3 → analog_sel 0/1/2; Follow+240p → 0; Follow+480p → 1.
# GREEN = analog_sel_policy.hpp (Plex.sv lockstep). RED = live content hop.
# Soft-skip is not a pass. Do not invent glass Hz.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
fails=0

grep -q "(analog_menu == 2'd1) ? 2'd0" "$PLEX" || {
  echo "FAIL Plex.sv analog_menu 1 must map analog_sel 0" >&2
  fails=$((fails + 1))
}
grep -q "(analog_menu == 2'd2) ? 2'd1" "$PLEX" || {
  echo "FAIL Plex.sv analog_menu 2 must map analog_sel 1" >&2
  fails=$((fails + 1))
}
grep -q "analog_from_content = (content_res_sel == 2'd0) ? 2'd0 : 2'd1" "$PLEX" || {
  echo "FAIL Plex.sv Follow+240p/480p analog_from_content missing" >&2
  fails=$((fails + 1))
}

make -C "$ROOT" "$ROOT/build/test_analog_sel_policy" "$ROOT/build/test_analog_sel_policy_red"

set +e
GREEN_OUT=$("$ROOT/build/test_analog_sel_policy" 2>&1)
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
echo "analog_sel_policy GREEN true rc=$GREEN_RC"
if [ "$GREEN_RC" -ne 0 ]; then
  echo "GREEN analog_sel_policy BLOCKED" >&2
  fails=$((fails + 1))
fi

set +e
RED_OUT=$("$ROOT/build/test_analog_sel_policy_red" 2>&1)
RED_RC=$?
set -e
printf '%s\n' "$RED_OUT"
echo "analog_sel_policy RED (live content as analog jump) true rc=$RED_RC"
if [ "$RED_RC" -eq 0 ]; then
  echo "FAIL RED: live-content hop unexpectedly passed" >&2
  fails=$((fails + 1))
elif ! printf '%s\n' "$RED_OUT" | grep -q "live-content Follow 240p"; then
  echo "FAIL RED twin must quote live-content Follow hop" >&2
  fails=$((fails + 1))
else
  echo "OK RED: live content change without reset treated as analog jump"
fi

if [ "$fails" -ne 0 ]; then
  echo "test_analog_sel_policy: $fails failure(s)" >&2
  exit 1
fi
echo "test_analog_sel_policy: OK"
exit 0
