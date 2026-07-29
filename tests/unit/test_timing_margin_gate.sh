#!/usr/bin/env bash
# Mutation-verify scripts/check_timing_margin.py in both directions.
# Fixtures only — never touches the live device or Quartus.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_timing_margin.py"
BASE="$ROOT/assets/timing_margin_baseline.json"
WORK="$ROOT/build/timing-margin-gate"
REAL_STA="${TIMING_MARGIN_REAL_STA:-$ROOT/.worktrees/integ-tip-fit/fpga/Plex_MiSTer/remote_out/slot1/Plex.sta.rpt}"

rm -rf "$WORK"
mkdir -p "$WORK"

chmod +x "$GATE"

# Minimal STA with Setup/Hold summaries matching Quartus table shape.
write_sta() {
  local path="$1" ddr_setup="$2" sys_hold="$3" ddr_tns="${4:-0.000}" sys_tns="${5:-0.000}"
  cat >"$path" <<EOF
; Fmax Summary                                                                                                            ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; Fmax       ; Restricted Fmax ; Clock Name                                                                        ; Note ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; 23.27 MHz  ; 23.27 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
; 92.14 MHz  ; 92.14 MHz       ; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+

+------------------------------------------------------------------------------------------------------------+
; Setup Summary                                                                                              ;
+-----------------------------------------------------------------------------------+--------+---------------+
; Clock                                                                             ; Slack  ; End Point TNS ;
+-----------------------------------------------------------------------------------+--------+---------------+
; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ; ${ddr_setup}  ; ${ddr_tns}         ;
; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ; 0.712  ; 0.000         ;
+-----------------------------------------------------------------------------------+--------+---------------+

+-----------------------------------------------------------------------------------------------------------+
; Hold Summary                                                                                              ;
+-----------------------------------------------------------------------------------+-------+---------------+
; Clock                                                                             ; Slack ; End Point TNS ;
+-----------------------------------------------------------------------------------+-------+---------------+
; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ; ${sys_hold} ; ${sys_tns}         ;
; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ; 0.311 ; 0.000         ;
+-----------------------------------------------------------------------------------+-------+---------------+
EOF
}

run_case() {
  local label="$1" want_rc="$2"
  shift 2
  local out rc
  set +e
  out=$(python3 "$GATE" "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  |"
  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "FAIL test_timing_margin_gate: $label rc=$rc want=$want_rc" >&2
    exit 1
  fi
  echo "OK $label rc=$rc"
}

echo "=== mutation: PASS synthetic STA at wtime4 reference ==="
write_sta "$WORK/pass.sta" "0.284" "0.244"
run_case "pass_wtime4" 0 --sta-rpt "$WORK/pass.sta" --baseline "$BASE"
grep -q "PASS timing_margin" <<<"$(python3 "$GATE" --sta-rpt "$WORK/pass.sta" --baseline "$BASE" 2>&1)" || {
  echo "FAIL: pass case must print PASS timing_margin" >&2
  exit 1
}

echo "=== mutation: PASS synthetic STA with small erosion inside 50ps budget ==="
# 0.284 - 0.026 = 0.258 (matches integ tip); under 0.05 budget
write_sta "$WORK/pass_eroded.sta" "0.258" "0.240"
run_case "pass_small_erosion" 0 --sta-rpt "$WORK/pass_eroded.sta" --baseline "$BASE"

echo "=== mutation: FAIL synthetic STA with clk_ddr setup regressed past budget ==="
# floor = 0.284 - 0.05 = 0.234; 0.200 is well below
write_sta "$WORK/fail_setup.sta" "0.200" "0.244"
run_case "fail_setup_regression" 1 --sta-rpt "$WORK/fail_setup.sta" --baseline "$BASE"
set +e
fail_out=$(python3 "$GATE" --sta-rpt "$WORK/fail_setup.sta" --baseline "$BASE" 2>&1)
set -e
grep -q "TIMING_MARGIN_REJECTED" <<<"$fail_out" || {
  echo "FAIL: degraded setup must print TIMING_MARGIN_REJECTED" >&2
  exit 1
}
grep -q "REGRESSED\\|actual=0.2" <<<"$fail_out" || {
  echo "FAIL: degraded setup must quote regression/actual" >&2
  exit 1
}

echo "=== mutation: FAIL synthetic STA with clk_sys hold regressed past budget ==="
write_sta "$WORK/fail_hold.sta" "0.284" "0.100"
run_case "fail_hold_regression" 1 --sta-rpt "$WORK/fail_hold.sta" --baseline "$BASE"

echo "=== mutation: FAIL negative setup slack ==="
write_sta "$WORK/fail_neg.sta" "-0.010" "0.244"
run_case "fail_neg_slack" 1 --sta-rpt "$WORK/fail_neg.sta" --baseline "$BASE"

echo "=== mutation: SKIP-NOT-PASS absent STA ==="
run_case "absent_sta" 77 --sta-rpt "$WORK/no-such.sta" --baseline "$BASE"
set +e
abs_out=$(python3 "$GATE" --sta-rpt "$WORK/no-such.sta" --baseline "$BASE" 2>&1)
set -e
grep -q "SKIP-NOT-PASS" <<<"$abs_out" || {
  echo "FAIL: absent STA must print SKIP-NOT-PASS" >&2
  exit 1
}

echo "=== mutation: SKIP-NOT-PASS malformed STA (no Setup/Hold summaries) ==="
printf 'this is not a quartus sta report\n' >"$WORK/malformed.sta"
run_case "malformed_sta" 77 --sta-rpt "$WORK/malformed.sta" --baseline "$BASE"

echo "=== mutation: SKIP-NOT-PASS empty STA ==="
: >"$WORK/empty.sta"
run_case "empty_sta" 77 --sta-rpt "$WORK/empty.sta" --baseline "$BASE"

if [[ -f "$REAL_STA" ]]; then
  echo "=== green: real integ-tip STA must PASS under wtime4+50ps budget ==="
  run_case "real_integ_tip" 0 --sta-rpt "$REAL_STA" --baseline "$BASE"
  set +e
  real_out=$(python3 "$GATE" --sta-rpt "$REAL_STA" --baseline "$BASE" 2>&1)
  set -e
  grep -q "worst_setup" <<<"$real_out" || {
    echo "FAIL: real STA run must quote worst_setup raw" >&2
    exit 1
  }
  grep -q "0.258" <<<"$real_out" || {
    echo "FAIL: real STA run must quote raw clk_ddr setup 0.258" >&2
    exit 1
  }
else
  echo "NOTE: real STA not present at $REAL_STA — skipped green real-file check"
fi

# Baseline must pin wtime4 numbers — otherwise PASS is vacuous.
python3 - <<PY
import json
from pathlib import Path
b=json.loads(Path("$BASE").read_text())
assert abs(b["clocks"]["clk_ddr"]["setup_ns"] - 0.284) < 1e-9, b
assert abs(b["clocks"]["clk_sys"]["hold_ns"] - 0.244) < 1e-9, b
assert abs(b["max_setup_regression_ns"] - 0.05) < 1e-9, b
print("OK baseline pins wtime4 0.284/0.244 and 50ps budget")
PY

echo "test_timing_margin_gate: OK pass, fail-regression, fail-neg, skip-absent, skip-malformed"
