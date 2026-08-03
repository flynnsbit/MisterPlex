#!/usr/bin/env bash
# Mutation-verify scripts/check_pll_clock_contract.py (red-before-green).
# No Quartus fit. No device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_pll_clock_contract.py"
CONTRACT="$ROOT/assets/pll_clock_contract.json"
PLL="$ROOT/fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
SDC="$ROOT/fpga/Plex_MiSTer/Plex.sdc"
WORK="$ROOT/build/pll-clock-contract-gate"

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$GATE"

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
    echo "FAIL test_pll_clock_contract: $label rc=$rc want=$want_rc" >&2
    exit 1
  fi
  echo "OK $label rc=$rc"
}

echo "=== green: shipping tree matches contract ==="
run_case "shipping_pass" 0 --contract "$CONTRACT" --pll "$PLL" --sdc "$SDC"
pass_out=$(python3 "$GATE" --contract "$CONTRACT" --pll "$PLL" --sdc "$SDC" 2>&1)
grep -q "PASS pll_clock_contract" <<<"$pass_out" || {
  echo "FAIL: must print PASS pll_clock_contract" >&2
  exit 1
}
grep -q "P720_CLK_ARITH_BEGIN" <<<"$pass_out" || {
  echo "FAIL: must print 720p arithmetic table" >&2
  exit 1
}
grep -q "WALL" <<<"$pass_out" || {
  echo "FAIL: must state 1280-wide@60 WALL" >&2
  exit 1
}

echo "=== red: accidental 25 MHz PLL bump without allow ==="
cp "$PLL" "$WORK/pll_bump.v"
sed -i 's/output_clock_frequency0("20.000000 MHz")/output_clock_frequency0("25.000000 MHz")/' \
  "$WORK/pll_bump.v"
run_case "bump_without_allow" 1 --contract "$CONTRACT" --pll "$WORK/pll_bump.v" --sdc "$SDC"
set +e
bump_out=$(python3 "$GATE" --contract "$CONTRACT" --pll "$WORK/pll_bump.v" --sdc "$SDC" 2>&1)
set -e
grep -q "PLL_CONTRACT_REJECTED" <<<"$bump_out" || {
  echo "FAIL: unauthorised bump must REJECT" >&2
  exit 1
}

echo "=== green: bump allowed only with --allow-pll-bump (still not a fit proof) ==="
run_case "bump_with_allow" 0 --contract "$CONTRACT" --pll "$WORK/pll_bump.v" --sdc "$SDC" --allow-pll-bump

echo "=== red: STA Fmax below activated target B_30_90 ==="
cat >"$WORK/low_fmax.sta" <<'EOF'
; Fmax Summary                                                                                                            ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; Fmax       ; Restricted Fmax ; Clock Name                                                                        ; Note ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; 23.46 MHz  ; 23.46 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
; 96.83 MHz  ; 96.83 MHz       ; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
EOF
run_case "sta_below_target_b" 1 \
  --contract "$CONTRACT" --pll "$PLL" --sdc "$SDC" \
  --sta-rpt "$WORK/low_fmax.sta" --activate-target B_30_90

echo "=== green: STA Fmax meets shipping 20/90 ==="
cat >"$WORK/ok_fmax.sta" <<'EOF'
; Fmax Summary                                                                                                            ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; Fmax       ; Restricted Fmax ; Clock Name                                                                        ; Note ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
; 32.59 MHz  ; 32.59 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
; 97.43 MHz  ; 97.43 MHz       ; emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
+------------+-----------------+-----------------------------------------------------------------------------------+------+
EOF
run_case "sta_meets_shipping" 0 \
  --contract "$CONTRACT" --pll "$PLL" --sdc "$SDC" --sta-rpt "$WORK/ok_fmax.sta"

echo "=== skip: absent STA with --sta-rpt ==="
run_case "sta_absent" 77 \
  --contract "$CONTRACT" --pll "$PLL" --sdc "$SDC" --sta-rpt "$WORK/no-such.sta"

echo "=== red: SDC missing contract pointer ==="
cp "$SDC" "$WORK/sdc_nopt.sdc"
# strip contract pointer lines only
sed -i '/pll_clock_contract/d' "$WORK/sdc_nopt.sdc"
sed -i '/check_pll_clock_contract/d' "$WORK/sdc_nopt.sdc"
run_case "sdc_no_ptr" 1 --contract "$CONTRACT" --pll "$PLL" --sdc "$WORK/sdc_nopt.sdc"

echo "test_pll_clock_contract: OK green/red/skip mutations"
