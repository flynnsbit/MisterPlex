#!/usr/bin/env bash
# NEGATIVE elab twin: FATAL_ON_STATIC_OVERFLOW=1 with 720p + 512KiB MUST fail elab.
# A guard that cannot fail is tautological (forbidden pattern #5).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
rtl_sim_require_verilator "ddr_bank_geom_fatal"

BUILD_DIR="$ROOT/build/verilator/ddr_bank_geom_fatal"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Tiny top that enables FATAL with overflowing geometry.
cat >"$BUILD_DIR/fatal_top.sv" <<'SV'
module fatal_top (input wire clk);
  ddr_bank_geom_guard #(
    .CODED_W(1280), .CODED_H(720), .Y_STRIDE(1280), .C_STRIDE(640),
    .BANK_STRIDE(32'h0008_0000), .DOORBELL_PAGE(32'h1000),
    .FATAL_ON_STATIC_OVERFLOW(1'b1)
  ) u_g (
    .clk(clk), .reset(1'b0),
    .rt_frame_bytes(32'd0), .rt_bank_stride(32'd0), .check_en(1'b0),
    .frame_bytes(), .usable_bytes(), .overflow_now(), .overflow_reject()
  );
endmodule
SV

set +e
OUT=$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module fatal_top -Wno-fatal \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bank_geom_guard.sv" \
  "$BUILD_DIR/fatal_top.sv" 2>&1)
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_bank_geom_fatal_elab true rc=$RC"

# Expect HARD FAIL (non-zero). rc=0 would mean the guard is toothless.
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL ddr_bank_geom_fatal: elab succeeded — FATAL path has no teeth" >&2
  exit 1
fi
if ! grep -qiE 'STATIC_OVERFLOW|Cannot find|error|Error' <<<"$OUT"; then
  echo "FAIL ddr_bank_geom_fatal: non-zero rc but no overflow-related error text" >&2
  exit 1
fi
echo "PASS ddr_bank_geom_fatal elab_rejected (NEG teeth)"
exit 0
