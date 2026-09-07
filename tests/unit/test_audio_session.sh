#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/verilator/audio_session"
mkdir -p "$OUT/compiler-scratch"
export TMPDIR="$OUT/compiler-scratch"
python3 "$ROOT/scripts/generate_audio_session_abi.py" --check
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
  --Mdir "$OUT" --top-module audio_session_tb_top -Wno-fatal \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host/libmisterplex" \
  "$ROOT/tests/rtl/audio_session_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/sys/alsa.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/audio_session_mailbox.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/audio_session_ddr_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv" \
  "$ROOT/tests/rtl/audio_session_tb.cpp"
"$OUT/Vaudio_session_tb_top"
