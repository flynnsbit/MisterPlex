#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/verilator/audio_session"
EXTRA=()
if [[ "${AUDIO_REAL_CDC_CASES:-0}" == 1 ]]; then
  OUT="$OUT-real-cdc"
  EXTRA=(-GAUDIO_CLOCK_RATE=24576000 -GTEST_CDC_DATA_DELAY=1 -CFLAGS "-DAUDIO_REAL_CDC_CASES")
fi
mkdir -p "$OUT/compiler-scratch"
export TMPDIR="$OUT/compiler-scratch"
python3 "$ROOT/scripts/generate_audio_session_abi.py" --check
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
  "${EXTRA[@]}" \
  --Mdir "$OUT" --top-module audio_session_tb_top -Wno-fatal \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" -I"$ROOT/fpga/Plex_MiSTer" \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/frozen-host" \
  "$ROOT/tests/rtl/audio_session_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/sys/alsa.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/audio_session_mailbox.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/audio_session_ddr_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv" \
  "$ROOT/tests/rtl/audio_session_tb.cpp"
"$OUT/Vaudio_session_tb_top"
