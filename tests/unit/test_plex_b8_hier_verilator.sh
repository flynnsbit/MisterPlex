#!/usr/bin/env bash
# B8/B13 product hierarchy: PRESENT_BEAM_960 fallback + PLXG runtime DE.
# Red twin FAULT_B8_NO_BEAM: no beam → legacy O[4] (rc!=0 + REPRO).
# Red twin FAULT_B8_FORCE_ALWAYS: COLLISION #5 unconditional force (rc!=0 + REPRO).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
fi

build_one() {
  local tag="$1"
  shift
  local BUILD_DIR="$ROOT/build/verilator/plex_b8_hier_${tag}"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  local RTL=(
    "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/present_cadence.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
    "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
    "$ROOT/tests/rtl/plex_b8_hier_tb_top.sv"
    "$ROOT/tests/rtl/plex_b8_hier_tb.cpp"
  )
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
    --Mdir "$BUILD_DIR" \
    --top-module plex_b8_hier_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    "$@" \
    "${RTL[@]}" >&2
  printf '%s\n' "$BUILD_DIR/Vplex_b8_hier_tb_top"
}

echo "RTL SIM: using $VERILATOR_VERSION" >&2

# --- Good arm: PRESENT_BEAM_960 + runtime PLXG DE ---
EXE_GOOD="$(build_one good \
  +define+PRESENT_BEAM_960 \
  +define+DDR_FRAME_STORE \
  -CFLAGS "-std=c++17 -O2")"
set +e
OUT_GOOD="$("$EXE_GOOD" 2>&1)"
RC_GOOD=$?
set -e
printf '%s\n' "$OUT_GOOD"
echo "plex_b8_hier_good true rc=$RC_GOOD"
if [[ "$RC_GOOD" -ne 0 ]]; then
  echo "B8 good arm FAILED" >&2
  exit "$RC_GOOD"
fi
if ! printf '%s\n' "$OUT_GOOD" | grep -q 'PASS plxg runtime DE exact equality'; then
  echo "FAIL good arm missing PLXG runtime DE proof" >&2
  exit 1
fi

# --- Red twin A: no beam force (PLXG idle → legacy 320) ---
EXE_FAULT="$(build_one fault \
  +define+FAULT_B8_NO_BEAM \
  +define+DDR_FRAME_STORE \
  -CFLAGS "-std=c++17 -O2 -DFAULT_B8_NO_BEAM")"
set +e
OUT_FAULT="$("$EXE_FAULT" 2>&1)"
RC_FAULT=$?
set -e
printf '%s\n' "$OUT_FAULT"
echo "plex_b8_hier_fault true rc=$RC_FAULT"
if [[ "$RC_FAULT" -eq 0 ]]; then
  echo "FAIL red twin passed — cannot see B8 defect" >&2
  exit 1
fi
if ! printf '%s\n' "$OUT_FAULT" | grep -q 'REPRO b8-plxg-tied-legacy'; then
  echo "FAIL red twin missing REPRO marker" >&2
  exit 1
fi
echo "PASS red twin NO_BEAM REPRO (rc=$RC_FAULT)"

# --- Red twin B: COLLISION #5 unconditional force overrides PLXG ---
EXE_C5="$(build_one force_always \
  +define+PRESENT_BEAM_960 \
  +define+FAULT_B8_FORCE_ALWAYS \
  +define+DDR_FRAME_STORE \
  -CFLAGS "-std=c++17 -O2 -DFAULT_B8_FORCE_ALWAYS")"
set +e
OUT_C5="$("$EXE_C5" 2>&1)"
RC_C5=$?
set -e
printf '%s\n' "$OUT_C5"
echo "plex_b8_hier_force_always true rc=$RC_C5"
if [[ "$RC_C5" -eq 0 ]]; then
  echo "FAIL COLLISION #5 twin passed — cannot see force-overrides-plxg" >&2
  exit 1
fi
if ! printf '%s\n' "$OUT_C5" | grep -q 'REPRO collision5-force-overrides-plxg'; then
  echo "FAIL COLLISION #5 twin missing REPRO marker" >&2
  exit 1
fi
echo "PASS red twin COLLISION #5 REPRO (rc=$RC_C5)"

# --- Red twin C: disable ignored (store geom forced under owned disable) ---
EXE_DIS="$(build_one disable_ign \
  +define+PRESENT_BEAM_960 \
  +define+DDR_FRAME_STORE \
  +define+FAULT_B8_DISABLE_IGNORED \
  -CFLAGS "-std=c++17 -O2 -DFAULT_B8_DISABLE_IGNORED")"
set +e
OUT_DIS="$("$EXE_DIS" 2>&1)"
RC_DIS=$?
set -e
printf '%s\n' "$OUT_DIS"
echo "plex_b8_hier_disable_ign true rc=$RC_DIS"
if [[ "$RC_DIS" -ne 2 ]] || ! printf '%s\n' "$OUT_DIS" | grep -q 'REPRO disable-ignored'; then
  echo "FAIL disable-ignored red twin did not REPRO (rc=$RC_DIS)" >&2
  exit 1
fi
echo "PASS red twin disable-ignored REPRO (rc=2)"

# --- Static: mux idle fallback + owned disable ---
MUX="$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
if ! grep -qE 'beam_fallback_960 = ~plxg_owned|force_native_960 = ~plxg_live' "$MUX"; then
  echo "FAIL mux missing idle-only beam fallback (COLLISION #5 / disable fix)" >&2
  exit 1
fi
if ! grep -q 'plxg_owned' "$MUX"; then
  echo "FAIL mux missing plxg_owned (explicit-disable ownership)" >&2
  exit 1
fi
if ! grep -q 'present_geom_enable = (beam_fallback_960 & ~plxg_owned)' "$MUX"; then
  echo "FAIL mux geom_enable still forced under owned disable" >&2
  exit 1
fi
if grep -n "force_native_960 = 1'b1" "$MUX" | grep -v FAULT_B8_FORCE_ALWAYS | grep -q .; then
  if grep -B2 "force_native_960 = 1'b1" "$MUX" | grep -q 'FAULT_B8_FORCE_ALWAYS'; then
    :
  else
    echo "FAIL mux still has unconditional force_native_960=1 outside fault twin" >&2
    exit 1
  fi
fi
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
if grep -E -q "plxg_wr_en[[:space:]]*=[[:space:]]*1'b0" "$PLEX" && \
   grep -E -q "plxg_commit[[:space:]]*=[[:space:]]*1'b0" "$PLEX"; then
  echo "FAIL Plex.sv still ties plxg_wr_en and plxg_commit to 0" >&2
  exit 1
fi
if ! grep -q "plex_present_geom_mux" "$PLEX"; then
  echo "FAIL Plex.sv does not instantiate product mux" >&2
  exit 1
fi
if ! grep -q 'plxg_frame_boundary' "$PLEX"; then
  echo "FAIL Plex.sv missing clk_sys plxg_frame_boundary (rd-duck #1)" >&2
  exit 1
fi
if grep -n 'frame_boundary(fabric_vsync_swap)' "$PLEX" | grep -q .; then
  echo "FAIL latch still driven by fabric_vsync_swap" >&2
  exit 1
fi
if ! grep -q "PHYS_BASE_720P" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"; then
  echo "FAIL present_core missing PHYS_BASE_720P" >&2
  exit 1
fi
echo "PASS static (mux owned-disable + clk_sys boundary + untied PLXG + OPTC)"
echo "plex_b8_hier ALL PASS"
exit 0
