#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/verilator/fpga_video_audio_feedback"
mkdir -p "$OUT"
mkdir -p "$OUT/compiler-scratch"
export TMPDIR="$OUT/compiler-scratch"
"$ROOT/scripts/run_verilator.sh" --binary --timing --assert --build -j 1 \
  --Mdir "$OUT" --top-module fpga_video_audio_feedback_tb -Wno-fatal \
  -I"$ROOT/fpga/Plex_MiSTer" \
  "$ROOT/tests/rtl/fpga_video_audio_feedback_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fpga_video_publish.sv"
"$OUT/Vfpga_video_audio_feedback_tb"
