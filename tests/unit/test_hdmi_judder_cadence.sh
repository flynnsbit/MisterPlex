#!/usr/bin/env bash
# Red-before-green gate for scripts/hdmi_judder_cadence.py
# A harness that cannot distinguish 3:2 / 2:1 / 2,2,2,4 / static on synthetic
# input is worthless on real glass capture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$ROOT/scripts/hdmi_judder_cadence.py"
FAILS=0

run_expect() {
  local label="$1" pattern="$2" expect="$3"
  shift 3 || true
  local out rc
  set +e
  out="$(python3 "$PY" --synthetic "$pattern" --expect-pattern "$expect" "$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s/^/  [$label] /"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL $label true rc=$rc (want 0)" >&2
    FAILS=$((FAILS + 1))
    return
  fi
  echo "OK $label true rc=$rc"
}

run_expect_fail() {
  # Naive trap: something that must NOT be classified as clean telecine.
  local label="$1" pattern="$2" bad_expect="$3"
  local out rc
  set +e
  out="$(python3 "$PY" --synthetic "$pattern" --expect-pattern "$bad_expect" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s/^/  [$label] /"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL $label: expected mismatch rc!=0 when forcing expect=$bad_expect" >&2
    FAILS=$((FAILS + 1))
    return
  fi
  echo "OK $label true rc=$rc (correctly rejected expect=$bad_expect)"
}

echo "=== judder cadence synthetic red-twin ==="

# GREEN: three product-relevant cadences
run_expect "clean_3_2" "3_2" "CLEAN_3_2" --cycles 16
run_expect "clean_2_1" "2_1" "CLEAN_2_1" --cycles 24
run_expect "path_224" "2_2_2_4" "PATH_2_2_2_4" --cycles 12

# GREEN: static must be FROZEN/STATIC — not infinite judder / not CLEAN_*
run_expect "static_field" "static" "FROZEN" --cycles 20

# GREEN: partial-frame motion still yields clean 2:1 (not frozen)
run_expect "partial_motion_2_1" "partial_motion" "CLEAN_2_1" --cycles 16

# RED twin: path must not be reported as clean 3:2 or 2:1
run_expect_fail "path_not_32" "2_2_2_4" "CLEAN_3_2"
run_expect_fail "path_not_21" "2_2_2_4" "CLEAN_2_1"
run_expect_fail "static_not_21" "static" "CLEAN_2_1"
run_expect_fail "32_not_21" "3_2" "CLEAN_2_1"

# Scalar ranking:
#   JUDDER = conformance (ties CLEAN_3_2 and CLEAN_2_1 at ~0; path higher)
#   HOLD_STDEV / HOLD_MAXDEV = absolute irregularity → 2_1 < 3_2 < 2224
parse_metrics() {
  local pat="$1"
  python3 "$PY" --synthetic "$pat" --cycles 16 2>/dev/null
}
m21="$(parse_metrics 2_1)"
m32="$(parse_metrics 3_2)"
mpath="$(parse_metrics 2_2_2_4)"
mstat="$(parse_metrics static)"
echo "$m21" | sed 's/^/  [m21] /'
echo "$m32" | sed 's/^/  [m32] /'
echo "$mpath" | sed 's/^/  [mpath] /'
j32="$(echo "$m32" | awk -F= '/^JUDDER=/{print $2}')"
j21="$(echo "$m21" | awk -F= '/^JUDDER=/{print $2}')"
jpath="$(echo "$mpath" | awk -F= '/^JUDDER=/{print $2}')"
jstat="$(echo "$mstat" | awk -F= '/^JUDDER=/{print $2}')"
s21="$(echo "$m21" | awk -F= '/^HOLD_STDEV=/{print $2}')"
s32="$(echo "$m32" | awk -F= '/^HOLD_STDEV=/{print $2}')"
spath="$(echo "$mpath" | awk -F= '/^HOLD_STDEV=/{print $2}')"
d21="$(echo "$m21" | awk -F= '/^HOLD_MAXDEV=/{print $2}')"
d32="$(echo "$m32" | awk -F= '/^HOLD_MAXDEV=/{print $2}')"
dpath="$(echo "$mpath" | awk -F= '/^HOLD_MAXDEV=/{print $2}')"
echo "JUDDER_3_2=$j32 JUDDER_2_1=$j21 JUDDER_PATH=$jpath JUDDER_STATIC=$jstat"
echo "HOLD_STDEV_2_1=$s21 HOLD_STDEV_3_2=$s32 HOLD_STDEV_PATH=$spath"
echo "HOLD_MAXDEV_2_1=$d21 HOLD_MAXDEV_3_2=$d32 HOLD_MAXDEV_PATH=$dpath"
python3 - "$j32" "$j21" "$jpath" "$jstat" "$s21" "$s32" "$spath" "$d21" "$d32" "$dpath" <<'PY' || FAILS=$((FAILS + 1))
import sys
j32, j21, jpath, jstat, s21, s32, spath, d21, d32, dpath = map(float, sys.argv[1:])
# Conformance: cleans ~0; path worse
assert j32 < 0.05 and j21 < 0.05, (j32, j21)
assert jpath > j32 and jpath > j21, (jpath, j32, j21)
assert jstat == 0.0, jstat
# Absolute irregularity ordering (the decision metric): 2_1 < 3_2 < 2224
assert s21 < s32 < spath, (s21, s32, spath)
assert d21 < d32 < dpath, (d21, d32, dpath)
# Exact synthetic expectations (population stats)
assert abs(s21 - 0.0) < 1e-9 and abs(d21 - 0.0) < 1e-9
assert abs(s32 - 0.5) < 1e-9 and abs(d32 - 0.5) < 1e-9
assert abs(spath - (0.75 ** 0.5)) < 1e-6  # stdev({2,2,2,4}) = sqrt(0.75)≈0.866
assert abs(dpath - 1.5) < 1e-9
print("OK judder_conformance_and_hold_irregularity_order")
PY

# Degenerate: too few frames via empty dir
td="$ROOT/build/judder_cadence_degen"
rm -rf "$td"
mkdir -p "$td"
set +e
out="$(python3 "$PY" --frames-dir "$td" 2>&1)"
rc=$?
set -e
echo "$out" | sed 's/^/  [degen] /'
if [[ "$rc" -ne 3 && "$rc" -ne 4 ]]; then
  echo "FAIL degen want rc 3 or 4 got $rc" >&2
  FAILS=$((FAILS + 1))
else
  echo "OK degen true rc=$rc"
fi

# Round-trip through PNG dir (proves --frames-dir path parent will use)
td2="$ROOT/build/judder_cadence_png"
rm -rf "$td2"
mkdir -p "$td2"
python3 "$PY" --synthetic 3_2 --cycles 10 --write-frames "$td2" >/dev/null
set +e
out="$(python3 "$PY" --frames-dir "$td2" --expect-pattern CLEAN_3_2 2>&1)"
rc=$?
set -e
echo "$out" | sed 's/^/  [png_dir] /'
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL png_dir true rc=$rc" >&2
  FAILS=$((FAILS + 1))
else
  echo "OK png_dir true rc=$rc"
fi

if [[ "$FAILS" -ne 0 ]]; then
  echo "test_hdmi_judder_cadence: $FAILS FAIL(s)" >&2
  exit 1
fi
echo "test_hdmi_judder_cadence: PASS"
exit 0
