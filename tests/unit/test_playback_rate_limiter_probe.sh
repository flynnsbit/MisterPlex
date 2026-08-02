#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
# Host: no daemon → NO-DATA rc=77
set +e
WINDOWS=1 WINDOW_S=1 sh "$ROOT/tools/playback_rate_limiter_probe.sh" \
  >"$ROOT/.agent-work/w-cpu-1/limiter_probe_unit_out.txt" 2>&1
rc=$?
set -e
echo "host_smoke_rc=$rc"
[ "$rc" -eq 77 ] || { echo "FAIL expected rc=77 got $rc"; exit 1; }
grep -q 'RESULT=NO-DATA reason=no_misterplexd' "$ROOT/.agent-work/w-cpu-1/limiter_probe_unit_out.txt" \
  || grep -q 'RESULT=NO-DATA' "$ROOT/.agent-work/w-cpu-1/limiter_probe_unit_out.txt" \
  || { echo "FAIL no NO-DATA"; exit 1; }
grep -q 'PRE_REGISTER H-A=CONSUMER_BP' "$ROOT/tools/playback_rate_limiter_probe.sh"
grep -q 'H-A needs pipe full OR wchan' "$ROOT/tools/playback_rate_limiter_probe.sh"
# Source quotes: serial present loop still true
grep -q 'sleep_for.*milliseconds(2)' "$ROOT/arm/misterplexd/media_player.cpp"
echo "RESULT=PASS test_playback_rate_limiter_probe"
exit 0
