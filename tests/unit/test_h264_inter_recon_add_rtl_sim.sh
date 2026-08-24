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
SKIP RTL SIM: Verilator not found; h264_inter_recon_add simulation was NOT run.
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

TOP="$ROOT/tests/rtl/h264_inter_recon_add_tb.sv"
TB="$ROOT/tests/rtl/h264_inter_recon_add_tb.cpp"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_recon_add.sv"
BUILD="$ROOT/build/verilator/h264_inter_recon_add"
BUILD_DROP="$ROOT/build/verilator/h264_inter_recon_add_drop_residual"
for f in "$TOP" "$TB" "$RTL"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -Rq 'h264_inter_recon_add u_u' "$ROOT/fpga/Plex_MiSTer/rtl" || ! grep -Rq 'h264_inter_recon_add u_v' "$ROOT/fpga/Plex_MiSTer/rtl"; then
  echo "RTL SIM ERROR: decode_stub does not residual-add chroma U/V" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_DROP"
echo "RTL SIM: using $VERILATOR_VERSION (h264_inter_recon_add)" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_inter_recon_add_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_inter_recon_add_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP" \
  --top-module h264_inter_recon_add_tb -Wno-fatal \
  +define+H264_INTER_RECON_FAULT_DROP_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
DROP_OUT="$($BUILD_DROP/Vh264_inter_recon_add_tb 2>&1)"
DROP_RC=$?
set -e
printf '%s\n' "$DROP_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_inter_recon_add_drop_residual "$DROP_RC" <<<"$DROP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_inter_recon_add red-check: dropped residual stayed pred-only"
