#!/usr/bin/env bash
# Real Verilator RTL sim: h264_i_mb_feed multi-MB P walker mb_skip_run boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_i_mb_feed pskip real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

FEED_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_i_mb_feed.sv"
CAVLC_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv"
IQ_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
IQ_SEQ_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_seq.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_i_mb_feed_pskip_tb_top.sv"
TB="$ROOT/tests/rtl/h264_i_mb_feed_pskip_tb.cpp"
BUILD="$ROOT/build/verilator/h264_i_mb_feed_pskip"

for f in "$FEED_RTL" "$CAVLC_RTL" "$IQ_RTL" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
for rel in rtl/h264_i_mb_feed.sv rtl/h264_cavlc_residual.sv rtl/h264_iq_idct_4x4.sv rtl/h264_iq_idct_seq.sv; do
  if ! grep -q "$rel" "$QIP"; then
    echo "RTL SIM ERROR: files.qip does not list product RTL $rel" >&2
    exit 2
  fi
done

mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_i_mb_feed_pskip_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$FEED_RTL" "$CAVLC_RTL" "$IQ_RTL" "$IQ_SEQ_RTL" "$TB"
"$BUILD/Vh264_i_mb_feed_pskip_tb_top"
echo "OK h264_i_mb_feed multi-MB P skip_run boundary RTL sim"
