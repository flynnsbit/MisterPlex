#!/usr/bin/env bash
# REAL RTL: I16 AC max_coeff=15 bit-position chain + decode_top AC texture + QP/chroma.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
  echo "REFUSE: ALLOW_MISSING_VERILATOR=1 is not a pass"; exit 2
fi
OSS="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
export OSS_CAD_SUITE="$OSS"
export PATH="$OSS/bin:$PATH"
OBJ=build/rtl_i16_ac_bits
rm -rf "$OBJ"; mkdir -p "$OBJ"
bash scripts/run_verilator.sh -Wall --cc --exe --build -O3 \
  -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-fatal -Wno-UNOPTFLAT -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-PINMISSING -Wno-GENUNNAMED \
  -CFLAGS "-O3" -Mdir "$OBJ" -Ifpga/Plex_MiSTer/rtl \
  --top-module i16_ac_bits_tb_top \
  tests/rtl/i16_ac_bits_tb_top.sv tests/rtl/i16_ac_bits_tb.cpp \
  fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv \
  fpga/Plex_MiSTer/rtl/h264_transform_dc.sv \
  fpga/Plex_MiSTer/rtl/h264_iq_idct_seq.sv \
  fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv \
  fpga/Plex_MiSTer/rtl/h264_decode_top.sv \
  fpga/Plex_MiSTer/rtl/h264_intra_pred.sv \
  -o i16_ac_bits_tb
"$OBJ/i16_ac_bits_tb"
echo "test_i16_ac_bits_rtl_sim: PASS"
