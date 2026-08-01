#!/usr/bin/env bash
# Mutation tests: missing/malformed instrument input must NOT become a number.
#
# Parent 2026-08-01 defects (personally hit):
#   1) getconf CLK_TCK empty → P=100*dt/(HZ*dwall) with HZ="" → every CPU 0.0
#   2) POSIX $12 = $1 then 2 under set -- → wrong utime/stime fields
#
# Method: inject the defect, assert non-zero / UNSCORED. Grep is not evidence.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/build/instrument_empty_$$"
mkdir -p "$DIR"
FAIL=0
FINDINGS=0

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/clk_tck.inc.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/proc_stat.inc.sh"

echo "=== M1: empty HZ must not yield pct=0.0 (must UNSCORED 77) ==="
# Legacy defect formula (what the parent hit):
legacy_cpu() {
  local dticks="$1" dwall="$2" hz="$3"
  # intentional defect: no empty check
  awk -v d="$dticks" -v e="$dwall" -v hz="$hz" \
    'BEGIN{printf "%.1f\n", (100.0*d)/(hz*e)}' 2>/dev/null
}
set +e
legacy_out=$(legacy_cpu 50 1 "")
legacy_rc=$?
set -e
echo "legacy_empty_hz out='${legacy_out}' awk_rc=${legacy_rc}"
# Document: legacy produces 0.0 or empty — either is the defect class if treated as PASS
if [[ "$legacy_out" == "0.0" || "$legacy_out" == "0" || -z "$legacy_out" ]]; then
  echo "PASS M1a: legacy empty HZ manufactures '${legacy_out:-empty}' (defect reproduced)"
else
  echo "NOTE M1a: legacy out='$legacy_out' (platform-dependent awk on /0)"
fi

set +e
cpu_pct_onecpu 50 1 "" >"$DIR/m1_safe.out" 2>&1
echo $? >"$DIR/m1_safe.rc"
set -e
echo "M1_safe true rc=$(cat "$DIR/m1_safe.rc")"
if [[ "$(cat "$DIR/m1_safe.rc")" -eq 77 ]]; then
  echo "PASS M1b: cpu_pct_onecpu empty HZ → rc=77 UNSCORED"
else
  echo "FAIL M1b: want rc=77 got $(cat "$DIR/m1_safe.rc")"
  FAIL=$((FAIL + 1))
  cat "$DIR/m1_safe.out" | sed 's/^/  /'
fi
if grep -qE 'pct=0\.0|pct=0$' "$DIR/m1_safe.out"; then
  echo "FINDING M1b: safe path still printed pct=0.0 on empty HZ"
  FINDINGS=$((FINDINGS + 1))
  FAIL=$((FAIL + 1))
fi

echo "=== M2: zero HZ must not yield finite pct ==="
set +e
cpu_pct_onecpu 50 1 0 >"$DIR/m2.out" 2>&1
echo $? >"$DIR/m2.rc"
set -e
echo "M2 true rc=$(cat "$DIR/m2.rc")"
if [[ "$(cat "$DIR/m2.rc")" -ne 0 ]]; then
  echo "PASS M2: zero HZ refused rc=$(cat "$DIR/m2.rc")"
else
  echo "FAIL M2: zero HZ returned 0"
  FAIL=$((FAIL + 1))
fi

echo "=== M3: good HZ yields a number (control) ==="
set +e
cpu_pct_onecpu 50 1 100 >"$DIR/m3.out" 2>&1
echo $? >"$DIR/m3.rc"
set -e
echo "M3 true rc=$(cat "$DIR/m3.rc") out=$(cat "$DIR/m3.out")"
if [[ "$(cat "$DIR/m3.rc")" -eq 0 ]] && grep -q 'pct=50.0' "$DIR/m3.out"; then
  echo "PASS M3: 50 ticks / (100*1s) = 50.0%"
else
  echo "FAIL M3: expected pct=50.0"
  FAIL=$((FAIL + 1))
  cat "$DIR/m3.out" | sed 's/^/  /'
fi

echo "=== M4: require_clk_tck with mocked empty getconf ==="
# Run in subshell that shadows getconf
set +e
(
  getconf() {
    if [[ "${1:-}" == "CLK_TCK" ]]; then
      printf ''   # empty success — the busybox class
      return 0
    fi
    command getconf "$@"
  }
  export -f getconf
  # resolve may derive from real /proc/stat — that is SUCCESS path
  require_clk_tck
  echo "require_rc=$?"
) >"$DIR/m4.out" 2>&1
echo $? >"$DIR/m4.rc"
set -e
echo "M4 outer_rc=$(cat "$DIR/m4.rc")"
cat "$DIR/m4.out" | sed 's/^/  /' | head -20
# After fix: either derived HZ=N or UNSCORED 77 — NEVER silent empty used as 0.
# require_clk_tck rc is in the subshell log (outer rc is echo's).
req_rc=$(grep -E '^require_rc=' "$DIR/m4.out" | tail -1 | cut -d= -f2)
echo "M4 require_rc=${req_rc:-missing}"
if grep -qE 'HZ=[1-9][0-9]* src=derived' "$DIR/m4.out"; then
  echo "PASS M4: empty getconf → derived HZ (not empty denominator)"
elif grep -q 'verdict=UNSCORED' "$DIR/m4.out" && [[ "${req_rc:-}" -eq 77 ]]; then
  echo "PASS M4: empty getconf → UNSCORED 77 (could not derive on this host)"
else
  echo "FAIL M4: empty getconf not handled req_rc=${req_rc:-missing}"
  FAIL=$((FAIL + 1))
fi
if grep -qE 'HZ=$|HZ= src' "$DIR/m4.out"; then
  echo "FINDING M4: printed empty HZ="
  FINDINGS=$((FINDINGS + 1))
  FAIL=$((FAIL + 1))
fi

echo "=== M5: /proc/stat parse — space in comm fools \$14, after-) is correct ==="
# Craft a synthetic stat line: pid (comm with spaces) state ... utime stime ...
# man 5 proc after ')': fields 1=state ... 12=utime 13=stime
# Build rest with known utime=111 stime=222
rest="R 1 1 1 0 -1 0 0 0 0 0 111 222 0 0 20 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
# Naive awk $14/$15 on full line WITH spaces in comm shifts fields
echo "42 (my daemon name) $rest" >"$DIR/fake_stat"
# Wrong parser (field numbers on whole line):
wrong=$(awk '{print $14+0, $15+0}' "$DIR/fake_stat")
# Right parser:
set +e
right=$(proc_stat_utime_stime "$DIR/fake_stat")
right_rc=$?
set -e
echo "M5 wrong_\$14='$wrong' right_after_paren='$right' right_rc=$right_rc"
if [[ "$right_rc" -ne 0 ]]; then
  echo "FAIL M5: after-paren parser rc=$right_rc"
  FAIL=$((FAIL + 1))
elif [[ "$right" != "111 222" ]]; then
  echo "FAIL M5: want '111 222' got '$right'"
  FAIL=$((FAIL + 1))
else
  echo "PASS M5b: after-paren recovers utime=111 stime=222"
fi
if [[ "$wrong" == "111 222" ]]; then
  echo "NOTE M5a: naive \$14 accidentally matched (comm space count) — still banned"
else
  echo "PASS M5a: naive \$14 got '$wrong' ≠ 111 222 (mutation shows silent wrong field)"
fi

echo "=== M6: set -- then \$12 is \$1+2 (POSIX) — document + refuse pattern ==="
# shellcheck disable=SC2086
set -- $(cat "$DIR/fake_stat")
# Under set --, $12 is the 12th word — NOT rest-field 12 when comm has spaces
set12="$12"
set13="$13"
echo "M6 set12='$set12' set13='$set13' (words after split on IFS)"
if [[ "$set12" == "111" && "$set13" == "222" ]]; then
  echo "NOTE M6: set-- \$12 happened to be utime for this fixture — still banned"
else
  echo "PASS M6: set-- \$12='$set12' ≠ utime 111 (parent defect class reproduced)"
fi

echo "=== M7: deploy dead-daemon (R priority) ==="
if [[ -x "$ROOT/tests/unit/test_deploy_restore_mutations.sh" ]]; then
  # Run only via full suite is heavy; call deploy path briefly via existing unit
  set +e
  bash "$ROOT/tests/unit/test_deploy_misterplexd.sh" >"$DIR/deploy.out" 2>&1
  echo $? >"$DIR/deploy.rc"
  set -e
  echo "deploy_unit true rc=$(cat "$DIR/deploy.rc")"
  if [[ "$(cat "$DIR/deploy.rc")" -eq 0 ]]; then
    echo "PASS M7: test_deploy_misterplexd green (includes dead-daemon red)"
  else
    echo "FAIL M7: deploy unit rc=$(cat "$DIR/deploy.rc")"
    FAIL=$((FAIL + 1))
    tail -30 "$DIR/deploy.out" | sed 's/^/  /'
  fi
else
  echo "FAIL M7 missing deploy unit"; FAIL=$((FAIL + 1))
fi

echo "=== M8: restore R5 geometry postcondition ==="
PC="$ROOT/scripts/restore_postconditions.sh"
rm -rf "$DIR/r5"
mkdir -p "$DIR/r5/bin" "$DIR/r5/state"
printf 'daemon-v1\n' >"$DIR/r5/prev.bin"
cp -f "$DIR/r5/prev.bin" "$DIR/r5/bin/misterplexd"
echo 1 >"$DIR/r5/state/n_daemon"
md5sum "$DIR/r5/bin/misterplexd" | awk '{print $1}' >"$DIR/r5/state/live_md5"
echo 200 >"$DIR/r5/state/http"
echo 1 >"$DIR/r5/state/started_after_restore"
printf 'DECODE=320x240\nPRESENT=fpga\n' >"$DIR/r5/misterplex.conf"
set +e
env RESTORE_ROOT="$DIR/r5" RESTORE_PREV="$DIR/r5/prev.bin" RESTORE_STATE="$DIR/r5/state" \
  RESTORE_EXPECT_GEOM=480 "$PC" >"$DIR/r5.out" 2>&1
echo $? >"$DIR/r5.rc"
set -e
echo "restore_R5 true rc=$(cat "$DIR/r5.rc")"
if [[ "$(cat "$DIR/r5.rc")" -eq 8 ]]; then
  echo "PASS M8: R5 wrong geometry rc=8"
else
  echo "FAIL M8: want rc=8 got $(cat "$DIR/r5.rc")"
  FAIL=$((FAIL + 1))
  cat "$DIR/r5.out" | sed 's/^/  /'
fi

echo "=== M9: define-parity T7 strip must RED (coverage hole if green) ==="
set +e
python3 "$ROOT/scripts/check_define_parity.py" --fault-strip-t7-native >"$DIR/t7.out" 2>&1
echo $? >"$DIR/t7.rc"
set -e
echo "defpar_t7 true rc=$(cat "$DIR/t7.rc")"
if [[ "$(cat "$DIR/t7.rc")" -ne 0 ]]; then
  echo "PASS M9: T7 strip → non-zero (gate can see NATIVE_V_1TO1)"
else
  echo "FINDING M9: T7 strip stayed GREEN — define-parity blind to T7 (UNSCORED not PASS)"
  FINDINGS=$((FINDINGS + 1))
  FAIL=$((FAIL + 1))
fi
# Green path must declare T7 inspection
set +e
python3 "$ROOT/scripts/check_define_parity.py" >"$DIR/t7ok.out" 2>&1
echo $? >"$DIR/t7ok.rc"
set -e
echo "defpar_ok true rc=$(cat "$DIR/t7ok.rc")"
if ! grep -q 'DEFINE_PARITY_T7_PRESENT_BEGIN' "$DIR/t7ok.out"; then
  echo "FINDING M9b: green define-parity did not print T7 coverage block"
  FINDINGS=$((FINDINGS + 1))
  FAIL=$((FAIL + 1))
else
  echo "PASS M9b: green define-parity declares T7 inspection block"
fi

echo "=== M10: production scripts must not use bare getconf||echo 100 ==="
# After fix, profile_c2 / source_rate / validate_playback / p480 must refuse empty
bad=0
for f in \
  scripts/profile_c2_present.sh \
  scripts/source_rate_rca.sh \
  scripts/validate_playback_controls_hw.sh \
  tests/hw/test_p480_ab_harness.sh
do
  if grep -nE 'getconf CLK_TCK 2>/dev/null \|\| echo 100' "$ROOT/$f" >/dev/null 2>&1; then
    echo "FINDING M10: $f still has getconf||echo 100 (empty success bypasses ||)"
    bad=1
    FINDINGS=$((FINDINGS + 1))
    FAIL=$((FAIL + 1))
  else
    echo "PASS M10: $f no bare getconf||echo 100"
  fi
done
if [[ "$bad" -eq 0 ]]; then
  echo "PASS M10 summary: no bare empty-bypass getconf"
fi

echo "=== M11: production stat parsers must not use bare awk \$14 on whole line for utime ==="
# Allow after-paren forms; flag simple '{print $14'
for f in \
  scripts/source_rate_rca.sh \
  scripts/validate_playback_controls_hw.sh \
  tests/hw/test_p480_ab_harness.sh \
  scripts/profile_c2_present.sh
do
  if grep -nE "awk '\{print \$14" "$ROOT/$f" >/dev/null 2>&1 \
     || grep -nE 'awk -v pid=.*\{print "PROC".*\$14' "$ROOT/$f" >/dev/null 2>&1 \
     || grep -nE "cut -d' ' -f14,15" "$ROOT/$f" >/dev/null 2>&1; then
    echo "FINDING M11: $f still uses whole-line \$14/cut -f14 for utime"
    FINDINGS=$((FINDINGS + 1))
    FAIL=$((FAIL + 1))
  else
    echo "PASS M11: $f no whole-line \$14 utime"
  fi
done

echo
echo "=== summary FAIL=$FAIL FINDINGS=$FINDINGS work=$DIR ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "test_instrument_empty_input: FAIL"
  exit 1
fi
echo "test_instrument_empty_input: OK"
exit 0
