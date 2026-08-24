#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_cabac_residual simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

TOP="$ROOT/tests/rtl/h264_cabac_residual_tb.sv"
TB="$ROOT/tests/rtl/h264_cabac_residual_tb.cpp"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cabac.sv"
INCDIR="$ROOT/fpga/Plex_MiSTer/rtl"
BUILD="$ROOT/build/verilator/h264_cabac_residual"
BUILD_CBF="$ROOT/build/verilator/h264_cabac_residual_force_cbf0"
for f in "$TOP" "$TB" "$RTL"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_cabac.sv' "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "RTL SIM ERROR: files.qip does not list rtl/h264_cabac.sv" >&2
  exit 2
fi
if ! grep -Rq 'h264_cabac_residual_4x4 u_cabac_res' "$ROOT/fpga/Plex_MiSTer/rtl"; then
  echo "RTL SIM ERROR: product decode_core does not instantiate h264_cabac_residual_4x4 u_cabac_res" >&2
  exit 2
fi
if ! grep -Rq 'use_cabac_res' "$ROOT/fpga/Plex_MiSTer/rtl" || ! grep -Rq 'cabac_res_start_r' "$ROOT/fpga/Plex_MiSTer/rtl"; then
  echo "RTL SIM ERROR: product decode_core does not gate CAVLC vs CABAC residual" >&2
  exit 2
fi
if ! grep -q 'Tables 9-12' "$RTL"; then
  echo "RTL SIM ERROR: h264_cabac.sv is missing Table 9-12 m/n ROM" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_CBF"
echo "RTL SIM: using $VERILATOR_VERSION (h264_cabac_residual)" >&2
INCFLAGS="-std=c++17 -O2 -I$ROOT/tests/rtl"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_cabac_residual_tb -Wno-fatal \
  +incdir+"$INCDIR" \
  -CFLAGS "$INCFLAGS" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_cabac_residual_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_CBF" \
  --top-module h264_cabac_residual_tb -Wno-fatal \
  +incdir+"$INCDIR" \
  +define+H264_CABAC_RES_FAULT_FORCE_CBF0 \
  -CFLAGS "$INCFLAGS -DH264_CABAC_RES_FAULT_FORCE_CBF0" \
  "$TOP" "$RTL" "$TB"
set +e
CBF_OUT="$($BUILD_CBF/Vh264_cabac_residual_tb 2>&1)"
CBF_RC=$?
set -e
printf '%s\n' "$CBF_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_cabac_residual_force_cbf0 "$CBF_RC" <<<"$CBF_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$CBF_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_cabac_residual red-check: forced coded_block_flag=0 stayed zero"
