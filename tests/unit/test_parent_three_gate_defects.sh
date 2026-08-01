#!/usr/bin/env bash
# Parent 2026-08-01 — three concrete gate-integrity defects, mutation-proven.
#
# (1) video_regression must not GREEN a mixed SPI-core + DDR-daemon (black screen)
#     and must declare when running bitstream identity is unobservable.
# (2) deploy/restore false greens — dead daemon, dual daemon, wrong root, no RBF restore.
# (3) COMPILE-FAIL / missing input must be RED or SKIP-NOT-PASS, never silent PASS.
#
# Host-only. Capture true rc directly (never through a pipe).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/build/parent_three_defects_$$"
mkdir -p "$DIR"
FAIL=0

run() {
  local name="$1"
  shift
  set +e
  "$@" >"$DIR/${name}.out" 2>&1
  local st=$?
  set -e
  echo "${name} true rc=${st}"
  echo "$st" >"$DIR/${name}.rc"
  return 0
}

expect_rc() {
  local name="$1" want="$2" why="$3"
  local st
  st=$(cat "$DIR/${name}.rc")
  if [[ "$st" -ne "$want" ]]; then
    echo "FAIL ${name}: want rc=${want} got ${st} (${why})"
    FAIL=$((FAIL + 1))
    tail -25 "$DIR/${name}.out" | sed 's/^/  /'
  else
    echo "PASS ${name}: rc=${st} (${why})"
  fi
}

expect_nonzero() {
  local name="$1" why="$2"
  local st
  st=$(cat "$DIR/${name}.rc")
  if [[ "$st" -eq 0 ]]; then
    echo "FAIL ${name}: stayed GREEN rc=0 (${why})"
    FAIL=$((FAIL + 1))
    tail -25 "$DIR/${name}.out" | sed 's/^/  /'
  else
    echo "PASS ${name}: red rc=${st} (${why})"
  fi
}

echo "======== (1) video_regression: running bitstream / mixed pair ========"
run vidreg bash "$ROOT/tests/unit/test_video_regression_liveness.sh"
expect_rc vidreg 0 "liveness suite (mixed pair RED + identity UNVERIFIED inside)"
# Spot-check the suite log for the mixed-state class and loud limitation.
if grep -q 'FAIL pair-mismatch' "$DIR/vidreg.out" \
  && grep -q 'SPI/DDR mix' "$DIR/vidreg.out" \
  && grep -q 'CORE_IDENTITY_UNVERIFIED' "$DIR/vidreg.out" \
  && grep -q 'on-disk md5≠fabric\|On-disk RBF md5' "$DIR/vidreg.out"; then
  echo "PASS vidreg_spot: mixed FAIL + CORE_IDENTITY_UNVERIFIED + on-disk≠fabric declared"
else
  echo "FAIL vidreg_spot: missing mixed/identity limitation markers"
  FAIL=$((FAIL + 1))
  rg -n 'pair-mismatch|CORE_IDENTITY|on-disk|fabric' "$DIR/vidreg.out" | head -20 | sed 's/^/  /'
fi

echo "======== (2) deploy + restore mutations ========"
run deploy_unit bash "$ROOT/tests/unit/test_deploy_misterplexd.sh"
expect_rc deploy_unit 0 "deploy unit: dead/dual/cross-root/disk-only RED + green control"

run restore_refuse env -u PAIR_ID bash "$ROOT/scripts/restore_misterplexd_prev.sh"
expect_rc restore_refuse 10 "half-restore banned (no RBF restore path)"

# R5 geometry on temp root (broken picture must not look restored)
PC="$ROOT/scripts/restore_postconditions.sh"
R5="$DIR/r5"
mkdir -p "$R5/bin" "$R5/state"
printf 'daemon\n' >"$R5/prev.bin"
cp -f "$R5/prev.bin" "$R5/bin/misterplexd"
echo 1 >"$R5/state/n_daemon"
md5sum "$R5/bin/misterplexd" | awk '{print $1}' >"$R5/state/live_md5"
echo 200 >"$R5/state/http"
echo 1 >"$R5/state/started_after_restore"
printf 'DECODE=320x240\nPRESENT=fpga\n' >"$R5/misterplex.conf"
run restore_r5 env RESTORE_ROOT="$R5" RESTORE_PREV="$R5/prev.bin" RESTORE_STATE="$R5/state" \
  RESTORE_EXPECT_GEOM=480 "$PC"
expect_rc restore_r5 8 "R5 DECODE 240 vs expect 480"

run depmut bash "$ROOT/tests/unit/test_deploy_restore_mutations.sh"
expect_rc depmut 0 "full deploy/restore mutation suite"

echo "======== (3) compile-fail / missing-input must not PASS ========"
# PINNOTFOUND with fake verilator exit 0 → run_verilator rc=2
cat >"$DIR/fake_vl.sh" <<'EOF'
#!/usr/bin/env bash
echo "%Error: PINNOTFOUND: pin 'deleted_param' not found"
exit 0
EOF
chmod +x "$DIR/fake_vl.sh"
run pinnotfound env VERILATOR="$DIR/fake_vl.sh" bash "$ROOT/scripts/run_verilator.sh" --version
expect_rc pinnotfound 2 "PINNOTFOUND hard-fail even when tool exits 0"

# clean control
cat >"$DIR/ok_vl.sh" <<'EOF'
#!/usr/bin/env bash
echo "Verilator OK"
exit 0
EOF
chmod +x "$DIR/ok_vl.sh"
run pin_ok env VERILATOR="$DIR/ok_vl.sh" bash "$ROOT/scripts/run_verilator.sh" --version
expect_rc pin_ok 0 "clean verilator control"

run fgg python3 "$ROOT/tests/unit/test_gate_false_green_guard.py"
expect_rc fgg 0 "RTL sim gates: missing VL ≠ exit 0; PINNOTFOUND RBG"

run geom bash "$ROOT/tests/unit/test_core_conf_geometry_gate.sh"
expect_rc geom 0 "unknown core md5 → SKIP-NOT-PASS 77 (not PASS)"

run pms bash "$ROOT/tests/unit/test_pms_baseline_gate.sh"
expect_rc pms 0 "live-pms missing deps → SKIP-NOT-PASS 77; red profile fails"

# skip summary: CRITICAL must not wrap to 0
run skip_sum python3 "$ROOT/scripts/run_with_skip_summary.py" --self-test
expect_rc skip_sum 0 "skip summary self-test (CRITICAL ≠ success)"

echo
echo "=== summary FAIL=$FAIL work=$DIR ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "test_parent_three_gate_defects: FAIL"
  exit 1
fi
echo "test_parent_three_gate_defects: OK"
exit 0
