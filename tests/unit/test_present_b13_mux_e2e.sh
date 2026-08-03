#!/usr/bin/env bash
# B13 E2E product mux→beam + native→legacy exit DE extent (rd-duck island).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_b13_mux_e2e"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
TB="$ROOT/tests/rtl/present_b13_mux_e2e_tb.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

[[ -f "$MUX" ]] || { echo "FAIL mux missing"; exit 1; }
grep -q 'plxg_owned' "$MUX" || { echo "FAIL mux missing plxg_owned"; exit 1; }
grep -q 'disable_legacy' "$MUX" || { echo "FAIL mux missing disable_legacy"; exit 1; }
grep -q 'FAULT_B13_DISABLE_ISLAND' "$MUX" || { echo "FAIL mux missing island RED hook"; exit 1; }
grep -q 'FAULT_B8_FORCE_ALWAYS' "$MUX" || { echo "FAIL mux missing FORCE red hook"; exit 1; }
# Mode-exit DE SoT: coded 624 (ddr_frame_layout), NOT presented 640 (rd-duck).
LAYOUT="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"
grep -q 'kPlex480pCodedWidth{624}' "$LAYOUT" || { echo "FAIL layout coded width"; exit 1; }
grep -q 'kPlex480pPresentedWidth{640}' "$LAYOUT" || { echo "FAIL layout presented"; exit 1; }
grep -q "LEG_CW = 11'd624" "$MUX" || { echo "FAIL LEG_CW not 624"; exit 1; }
if grep -E "LEG_DE_W[[:space:]]*=[[:space:]]*11'd640|LEG_CW[[:space:]]*=[[:space:]]*11'd640" "$MUX"; then
  echo "FAIL mode-exit uses presented 640 as beam DE (624-store island)"; exit 1
fi
if grep -nE "beam_de_leg \? 11'd640|disable_legacy \? 11'd640" "$MUX"; then
  echo "FAIL disable path hardcodes 640 DE"; exit 1
fi
grep -q 'beam_de_leg ? LEG_CW' "$MUX" || { echo "FAIL content_width disable not LEG_CW"; exit 1; }
grep -q 'beam_de_leg ? LEG_CH' "$MUX" || { echo "FAIL content_height disable not LEG_CH"; exit 1; }
echo "OK mode-exit DE SoT = coded 624 (layout); presented 640 rejected"

python3 - "$MUX" <<'PY'
import re, sys
m = open(sys.argv[1]).read()
s = re.sub(r"`ifdef FAULT_B13_DISABLE_ISLAND.*?`else(.*?)`endif", r"\1", m, flags=re.S)
if re.search(r"beam_de_960\s*=\s*beam_fallback_960\s*\|\s*disable", s):
    print("FAIL product ORs disable into 960 beam DE (island)"); sys.exit(1)
if not re.search(r"beam_de_leg\s*=\s*disable_legacy", s):
    print("FAIL missing beam_de_leg = disable_legacy"); sys.exit(1)
print("OK product beam_de idle-only; disable→leg")
PY

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module present_b13_mux_e2e_tb \
    -Mdir "$mdir" -DPRESENT_BEAM_960 "$@" \
    "$TB" "$BEAM" "$MUX" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -50 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"; return 0
  fi
  set +e
  "$mdir/Vpresent_b13_mux_e2e_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
GRC=$(cat "$OUT/green/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN rc=$GRC"; exit 1; }
grep -q "OK E2E mux→beam DE=624x480 exact" "$OUT/green/run.log" || { echo "FAIL 624"; exit 1; }
grep -q "OK E2E mux→beam DE=416x234 exact" "$OUT/green/run.log" || { echo "FAIL 416"; exit 1; }
grep -q "line_acc=416..416" "$OUT/green/run.log" || { echo "FAIL line416"; exit 1; }
grep -q "OK E2E idle fallback DE=960x540" "$OUT/green/run.log" || { echo "FAIL idle"; exit 1; }
grep -q "OK E2E native→legacy exit DE=624x480 exact geom_en=0" "$OUT/green/run.log" \
  || { echo "FAIL native→legacy exit"; exit 1; }
grep -q "PASS present_b13_mux_e2e GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN product mux→beam + exit"

run_one red_fault -DFAULT_B8_FORCE_ALWAYS
RRC=$(cat "$OUT/red_fault/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED fault rc=$RRC"; exit 1; }
grep -q "OK RED FAULT force pins 960x540 over PLXG 624x480" "$OUT/red_fault/run.log" \
  || { echo "FAIL red force marker"; exit 1; }
echo "OK RED FAULT_B8_FORCE_ALWAYS"

run_one red_island -DFAULT_B13_DISABLE_ISLAND
IRC=$(cat "$OUT/red_island/sim.rc")
[[ "$IRC" -eq 0 ]] || { echo "FAIL RED island rc=$IRC"; exit 1; }
grep -q "OK RED FAULT_B13_DISABLE_ISLAND: 960 DE + geom_en=0" "$OUT/red_island/run.log" \
  || { echo "FAIL red island marker"; exit 1; }
echo "OK RED FAULT_B13_DISABLE_ISLAND (w-mem disable_beam_de class)"

echo "PASS test_present_b13_mux_e2e true rc=0"
exit 0
