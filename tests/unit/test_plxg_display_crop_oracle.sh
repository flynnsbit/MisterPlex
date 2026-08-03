#!/usr/bin/env bash
# B21: PLXG q3 display/crop — 624/618 oracle + RED display=coded twin.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/plxg_display_crop"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
TB="$ROOT/tests/rtl/plxg_display_crop_oracle_tb.sv"
mkdir -p "$OUT"

echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Structural: must use plxg_dw, not only coded clone
grep -q 'plxg_disp_in_bounds' "$MUX" || { echo "FAIL no bounds check"; exit 1; }
grep -q 'plxg_dw' "$MUX" || { echo "FAIL no plxg_dw"; exit 1; }
# Product path must select plxg_dw when in-bounds (FAULT twin may clone coded).
grep -q 'plxg_disp_in_bounds ? plxg_dw' "$MUX" || {
  echo "FAIL product still display=coded only"; exit 1
}
grep -q 'FAULT_MUX_DISPLAY_EQ_CODED' "$MUX" || { echo "FAIL no red twin"; exit 1; }
# 12-bit end sum (no 11-bit wrap)
grep -q 'plxg_crop_end_x' "$MUX" || { echo "FAIL no 12-bit crop end"; exit 1; }
echo "OK mux structure B21 display/crop"

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module plxg_display_crop_oracle_tb \
    -Mdir "$mdir" "$@" -DPRESENT_BEAM_960 "$TB" "$MUX" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -40 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"; return 0
  fi
  set +e
  "$mdir/Vplxg_display_crop_oracle_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
[[ $(cat "$OUT/green/sim.rc") -eq 0 ]] || { echo "FAIL GREEN"; exit 1; }
grep -q "OK 624/618/crop3" "$OUT/green/run.log" || { echo "FAIL oracle"; exit 1; }
grep -q "OK OOB crop+display sanitized" "$OUT/green/run.log" || { echo "FAIL oob"; exit 1; }
grep -q "PASS plxg_display_crop_oracle GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN 624/618"

run_one red -DFAULT_MUX_DISPLAY_EQ_CODED
[[ $(cat "$OUT/red/sim.rc") -eq 0 ]] || { echo "FAIL RED"; exit 1; }
grep -q "REPRO_OK FAULT display=coded" "$OUT/red/run.log" || { echo "FAIL repro"; exit 1; }
echo "OK RED dead-q3 OOB class"

echo "PASS test_plxg_display_crop_oracle true rc=0"
