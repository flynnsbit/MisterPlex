#!/usr/bin/env bash
# POS/NEG controls for scripts/check_raster_clock_consistency.py (fixtures only).
# Live-tree scan is make raster-clock-consistency (pre-fit); not this unit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_raster_clock_consistency.py"

echo "EXECUTED test_raster_clock_consistency_gate"

set +e
out=$(python3 "$GATE" --self-test 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's|^|  |'

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL test_raster_clock_consistency_gate: self-test rc=$rc" >&2
  exit 1
fi
grep -q "EXECUTED check_raster_clock_consistency --self-test" <<<"$out" || {
  echo "FAIL: self-test must print EXECUTED" >&2
  exit 1
}
grep -q "PASS raster_clock_consistency self-test" <<<"$out" || {
  echo "FAIL: self-test must print PASS conclusion" >&2
  exit 1
}
grep -q "SELFTEST POS_exact24_tree: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_exact24_tree" >&2
  exit 1
}
grep -q "SELFTEST NEG_stale_297: rc=1" <<<"$out" || {
  echo "FAIL: missing NEG_stale_297" >&2
  exit 1
}
grep -q "SELFTEST NEG_rate_band_excludes_240: rc=1" <<<"$out" || {
  echo "FAIL: missing NEG_rate_band" >&2
  exit 1
}
grep -q "SELFTEST NEG_sot_drift: rc=1" <<<"$out" || {
  echo "FAIL: missing NEG_sot_drift" >&2
  exit 1
}
grep -q "SELFTEST NEG_pll_unrealisable: rc=1" <<<"$out" || {
  echo "FAIL: missing NEG_pll" >&2
  exit 1
}
grep -q "POS_cea60_1650" <<<"$out" || {
  echo "FAIL: missing CEA60 1650 positive control" >&2
  exit 1
}

echo "test_raster_clock_consistency_gate: OK"
