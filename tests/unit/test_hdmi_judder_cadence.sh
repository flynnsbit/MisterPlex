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

# Scalar ranking: PATH judder must be > CLEAN judder (when both scored)
j32="$(python3 "$PY" --synthetic 3_2 --cycles 16 2>/dev/null | awk -F= '/^JUDDER=/{print $2}')"
j21="$(python3 "$PY" --synthetic 2_1 --cycles 24 2>/dev/null | awk -F= '/^JUDDER=/{print $2}')"
jpath="$(python3 "$PY" --synthetic 2_2_2_4 --cycles 12 2>/dev/null | awk -F= '/^JUDDER=/{print $2}')"
jstat="$(python3 "$PY" --synthetic static --cycles 20 2>/dev/null | awk -F= '/^JUDDER=/{print $2}')"
echo "JUDDER_3_2=$j32 JUDDER_2_1=$j21 JUDDER_PATH=$jpath JUDDER_STATIC=$jstat"
python3 - "$j32" "$j21" "$jpath" "$jstat" <<'PY' || FAILS=$((FAILS + 1))
import sys
j32, j21, jpath, jstat = map(float, sys.argv[1:])
# Clean patterns near zero
assert j32 < 0.05, j32
assert j21 < 0.05, j21
# Pathological ranks worse than either clean
assert jpath > j32 and jpath > j21, (jpath, j32, j21)
# Static must not explode
assert jstat == 0.0, jstat
print("OK judder_scalar_order")
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
