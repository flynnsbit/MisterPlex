#!/usr/bin/env bash
# REAL RTL: mb_qp_delta wrap + I16 AC iq_idct_seq (max_coeff=15, skip_dc) vs parallel.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
  echo "REFUSE: ALLOW_MISSING_VERILATOR=1 is not a pass"
  exit 2
fi

OSS="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
if [[ ! -x "$OSS/bin/verilator" && -x "$HOME/.local/oss-cad-suite/bin/verilator" ]]; then
  OSS="$HOME/.local/oss-cad-suite"
fi
export OSS_CAD_SUITE="$OSS"
export PATH="$OSS/bin:$PATH"

OBJ="build/rtl_i16_ac_qp"
rm -rf "$OBJ"
mkdir -p "$OBJ"

bash scripts/run_verilator.sh -Wall --cc --exe --build -O3 \
  -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND \
  -CFLAGS "-O3" \
  -Mdir "$OBJ" \
  -Ifpga/Plex_MiSTer/rtl \
  --top-module i16_ac_qp_tb_top \
  tests/rtl/i16_ac_qp_tb_top.sv \
  tests/rtl/i16_ac_qp_tb.cpp \
  fpga/Plex_MiSTer/rtl/h264_transform_dc.sv \
  fpga/Plex_MiSTer/rtl/h264_iq_idct_seq.sv \
  fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv \
  -o i16_ac_qp_tb

"$OBJ/i16_ac_qp_tb"
echo "test_i16_ac_qp_rtl_sim: PASS"
