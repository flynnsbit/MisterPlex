#!/usr/bin/env bash
# B8 product hierarchy: PRESENT_BEAM_960 → 960×540 at present_core via product mux.
# Red twin FAULT_B8_NO_BEAM must exit non-zero with REPRO marker.
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
  # Verilator noise → stderr; only the exe path on stdout for capture.
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
    --Mdir "$BUILD_DIR" \
    --top-module plex_b8_hier_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    "$@" \
    "${RTL[@]}" >&2
  printf '%s\n' "$BUILD_DIR/Vplex_b8_hier_tb_top"
}

echo "RTL SIM: using $VERILATOR_VERSION" >&2

# --- Good arm: PRESENT_BEAM_960 + DDR_FRAME_STORE ---
# SV macros need +define+; -D is C++ only (would leave beam force OFF → false green risk).
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

# --- Red twin: no beam force (PLXG idle → legacy 320) ---
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
echo "PASS red twin REPRO (rc=$RC_FAULT)"

# --- Static: Plex.sv must not tie plxg_wr_en/commit and must force 960 ---
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
if grep -E -q "plxg_wr_en[[:space:]]*=[[:space:]]*1'b0" "$PLEX" && \
   grep -E -q "plxg_commit[[:space:]]*=[[:space:]]*1'b0" "$PLEX"; then
  echo "FAIL Plex.sv still ties plxg_wr_en and plxg_commit to 0" >&2
  exit 1
fi
if ! grep -q "PRESENT_BEAM_960" "$PLEX" || ! grep -q "11'd960" "$PLEX"; then
  echo "FAIL Plex.sv missing PRESENT_BEAM_960 960 force" >&2
  exit 1
fi
if ! grep -q "plex_present_geom_mux" "$PLEX"; then
  echo "FAIL Plex.sv does not instantiate product mux" >&2
  exit 1
fi
if ! grep -q "PHYS_BASE_720P" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"; then
  echo "FAIL present_core missing PHYS_BASE_720P" >&2
  exit 1
fi
echo "PASS Plex.sv B8 static (untied PLXG + 960 force + mux + OPTC params)"
echo "plex_b8_hier ALL PASS"
exit 0
