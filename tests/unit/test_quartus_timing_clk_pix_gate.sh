#!/usr/bin/env bash
# RED/GREEN twins for clk_pix/general[3] post-fit timing gates.
# Proves empty STA cannot PASS, missing general[3] rejects, green [0]/[2]/[3] passes.
# Soft-skip is NOT a pass. Prints EXECUTED.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_quartus_timing.py"
MARGIN="$ROOT/scripts/check_timing_margin.py"
ONEPASS="$ROOT/scripts/sta_onepass_interrogation.sh"
BASE720="$ROOT/assets/timing_margin_baseline_720p_compose.json"
WORK="$ROOT/build/quartus-timing-clk-pix-gate"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "EXECUTED test_quartus_timing_clk_pix_gate"

write_sta() {
  local path="$1"
  local include_pix="${2:-1}"
  local pix_setup="${3:-0.400}"
  local pix_fmax="${4:-35.00 MHz}"
  local ddr_setup="${5:-0.284}"
  local sys_hold="${6:-0.244}"
  {
    cat <<EOF
; Fmax Summary                                                                                                            ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; Fmax       ; Restricted Fmax ; Clock Name                                                                        ; Note ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; 23.27 MHz  ; 23.27 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
; 92.14 MHz  ; 92.14 MHz       ; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
EOF
    if [[ "$include_pix" == "1" ]]; then
      cat <<EOF
; ${pix_fmax}  ; ${pix_fmax}       ; emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
EOF
    fi
    cat <<EOF
+------------+-----------------+-----------------------------------------------------------------------------------+------+

+------------------------------------------------------------------------------------------------------------+
; Setup Summary                                                                                              ;
+-----------------------------------------------------------------------------------+--------+---------------+
; Clock                                                                             ; Slack  ; End Point TNS ;
+-----------------------------------------------------------------------------------+--------+---------------+
; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ; ${ddr_setup}  ; 0.000         ;
; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ; 0.712  ; 0.000         ;
EOF
    if [[ "$include_pix" == "1" ]]; then
      cat <<EOF
; emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk           ; ${pix_setup}  ; 0.000         ;
EOF
    fi
    cat <<EOF
+-----------------------------------------------------------------------------------+--------+---------------+

+-----------------------------------------------------------------------------------------------------------+
; Hold Summary                                                                                              ;
+-----------------------------------------------------------------------------------+-------+---------------+
; Clock                                                                             ; Slack ; End Point TNS ;
+-----------------------------------------------------------------------------------+-------+---------------+
; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ; ${sys_hold} ; 0.000         ;
; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ; 0.311 ; 0.000         ;
EOF
    if [[ "$include_pix" == "1" ]]; then
      cat <<EOF
; emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk           ; 0.150 ; 0.000         ;
EOF
    fi
    cat <<EOF
+-----------------------------------------------------------------------------------+-------+---------------+
EOF
  } >"$path"
}

# --- RED: empty STA must FAIL (not PASS, not soft-skip) ---
echo "=== RED: empty STA hollow gate ==="
: >"$WORK/empty.sta"
set +e
empty_out=$(python3 "$GATE" --sta-rpt "$WORK/empty.sta" 2>&1)
empty_rc=$?
set -e
printf '%s\n' "$empty_out" | sed 's|^|  |'
if [[ "$empty_rc" -eq 0 ]]; then
  echo "FAIL empty STA must not PASS" >&2
  exit 1
fi
if [[ "$empty_rc" -eq 77 ]]; then
  echo "FAIL empty STA soft-skip is NOT a pass for check_quartus_timing" >&2
  exit 1
fi
if [[ "$empty_rc" -ne 1 ]] || ! grep -q "QUARTUS_TIMING_REJECTED" <<<"$empty_out"; then
  echo "FAIL empty STA want rc=1 REJECTED got rc=$empty_rc" >&2
  exit 1
fi
grep -qE "empty/unparsed STA must not PASS|min_setup_rows|Setup Summary rows=0" <<<"$empty_out" || {
  echo "FAIL empty STA must name hollow/empty reason" >&2
  exit 1
}
echo "OK empty_sta REJECTED rc=1 EXECUTED"

# --- RED: missing general[3] with --require-clock ---
echo "=== RED: STA missing general[3] under --require-clock ==="
write_sta "$WORK/no_pix.sta" 0
set +e
nopix_out=$(python3 "$GATE" --sta-rpt "$WORK/no_pix.sta" --require-clock "general[3]" 2>&1)
nopix_rc=$?
set -e
printf '%s\n' "$nopix_out" | sed 's|^|  |'
if [[ "$nopix_rc" -ne 1 ]] || ! grep -q "required Setup clock substring 'general\[3\]'" <<<"$nopix_out"; then
  echo "FAIL missing general[3] must REJECT with require message" >&2
  exit 1
fi
echo "OK missing_general3 REJECTED EXECUTED"

# --- RED: Fmax below 29.7 ---
echo "=== RED: general[3] Fmax below 29.7 ==="
write_sta "$WORK/low_fmax.sta" 1 "0.400" "20.00 MHz"
set +e
low_out=$(python3 "$GATE" --sta-rpt "$WORK/low_fmax.sta" \
  --require-clock "general[3]" --min-fmax-mhz "general[3]:29.7" 2>&1)
low_rc=$?
set -e
printf '%s\n' "$low_out" | sed 's|^|  |'
if [[ "$low_rc" -ne 1 ]] || ! grep -qi "Fmax\|29.7\|required" <<<"$low_out"; then
  echo "FAIL low Fmax must REJECT" >&2
  exit 1
fi
echo "OK low_fmax REJECTED EXECUTED"

# --- GREEN: full [0]/[2]/[3] ---
echo "=== GREEN: STA with general[0]/[2]/[3] and Fmax>=29.7 ==="
write_sta "$WORK/green.sta" 1 "0.400" "35.00 MHz"
set +e
green_out=$(python3 "$GATE" --sta-rpt "$WORK/green.sta" \
  --require-clock "general[3]" --min-fmax-mhz "general[3]:29.7" 2>&1)
green_rc=$?
set -e
printf '%s\n' "$green_out" | sed 's|^|  |'
if [[ "$green_rc" -ne 0 ]] || ! grep -q "PASS timing" <<<"$green_out"; then
  echo "FAIL green STA must PASS" >&2
  exit 1
fi
echo "OK green_clk_pix PASS EXECUTED"

# --- RED: margin baseline missing clk_pix ---
echo "=== RED: timing_margin 720p baseline missing clk_pix ==="
write_sta "$WORK/margin_no_pix.sta" 0
set +e
mnp_out=$(python3 "$MARGIN" --sta-rpt "$WORK/margin_no_pix.sta" --baseline "$BASE720" 2>&1)
mnp_rc=$?
set -e
printf '%s\n' "$mnp_out" | sed 's|^|  |'
if [[ "$mnp_rc" -ne 1 ]] || ! grep -qE "require_present|clk_pix|MISSING" <<<"$mnp_out"; then
  echo "FAIL margin without clk_pix must REJECT" >&2
  exit 1
fi
echo "OK margin_missing_clk_pix REJECTED EXECUTED"

# --- GREEN: margin with clk_pix present ---
echo "=== GREEN: timing_margin 720p baseline with clk_pix ==="
set +e
mg_out=$(python3 "$MARGIN" --sta-rpt "$WORK/green.sta" --baseline "$BASE720" 2>&1)
mg_rc=$?
set -e
printf '%s\n' "$mg_out" | sed 's|^|  |'
if [[ "$mg_rc" -ne 0 ]] || ! grep -q "PASS timing_margin" <<<"$mg_out"; then
  echo "FAIL margin green must PASS" >&2
  exit 1
fi
echo "OK margin_clk_pix PASS EXECUTED"

# --- RED twin: onepass without general[3] ---
echo "=== RED: sta_onepass without general[3] ==="
set +e
op_out=$("$ONEPASS" "$WORK/no_pix.sta" "$WORK/onepass_red" 2>&1)
op_rc=$?
set -e
printf '%s\n' "$op_out" | sed 's|^|  |'
grep -q "STA_ONEPASS EXECUTED" <<<"$op_out" || {
  echo "FAIL onepass must print EXECUTED" >&2
  exit 1
}
if [[ "$op_rc" -eq 0 ]]; then
  echo "FAIL onepass without pix must not PASS" >&2
  exit 1
fi
echo "OK onepass_no_pix REJECTED rc=$op_rc EXECUTED"

# --- GREEN: onepass full ---
echo "=== GREEN: sta_onepass with general[3] ==="
set +e
opg_out=$("$ONEPASS" "$WORK/green.sta" "$WORK/onepass_green" 2>&1)
opg_rc=$?
set -e
printf '%s\n' "$opg_out" | sed 's|^|  |'
if [[ "$opg_rc" -ne 0 ]] || ! grep -q "STA_ONEPASS_PASS" <<<"$opg_out"; then
  echo "FAIL onepass green must PASS" >&2
  exit 1
fi
test -f "$WORK/onepass_green/sta_onepass_ok.txt" || {
  echo "FAIL onepass must write sta_onepass_ok.txt" >&2
  exit 1
}
echo "OK onepass_green PASS EXECUTED"

# Baseline pins require_present on clk_pix
export ROOT
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ["ROOT"])
b = json.loads((root / "assets/timing_margin_baseline_720p_compose.json").read_text())
assert b["clocks"]["clk_pix"]["require_present"] is True
assert b["clocks"]["clk_pix"]["setup_ns"] is None
assert float(b["clocks"]["clk_pix"]["min_setup_ns"]) == 0.0
assert "general[3]" in b["clocks"]["clk_pix"]["match"]
print("OK baseline_720p pins clk_pix require_present min_setup=0")
PY

echo "test_quartus_timing_clk_pix_gate: OK empty-RED missing-g3-RED low-fmax-RED green-PASS margin-RED/GREEN onepass-RED/GREEN"
