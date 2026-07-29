#!/usr/bin/env bash
# Execute h264_dpb_ddr with BRAM_REF=0 (pure-DDR fallback).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
  echo "REFUSE: ALLOW_MISSING_VERILATOR=1 is not a pass"
  exit 2
fi
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
export OSS_CAD_SUITE
V="$ROOT/scripts/run_verilator.sh"
OBJ="$ROOT/tests/rtl/obj_dir_dpb_bram_fb"
rm -rf "$OBJ"
mkdir -p "$OBJ"
# shellcheck disable=SC2086
$V --cc --exe -sv -O2 --top-module h264_dpb_bram_ref_tb_top \
  -Mdir "$OBJ" \
  -CFLAGS "-I$OBJ -DBRAM_REF_FALLBACK" \
  -DBRAM_REF_FALLBACK \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_bram_ref.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ddr_wr.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ddr_rd.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ddr.sv" \
  "$ROOT/tests/rtl/h264_dpb_bram_ref_tb_top.sv" \
  "$ROOT/tests/rtl/h264_dpb_bram_ref_tb.cpp"
make -C "$OBJ" -f Vh264_dpb_bram_ref_tb_top.mk -j"$(nproc)"
"$OBJ/Vh264_dpb_bram_ref_tb_top"
