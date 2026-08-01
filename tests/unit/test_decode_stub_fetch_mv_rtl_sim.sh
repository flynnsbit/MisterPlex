#!/usr/bin/env bash
# Product path: mvd → MVP → decode_stub fetch_mv_x/y_qpel (not hardwired 0).
# Twin: FAULT_FORCE_ZERO_FETCH_MV must RED.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; decode_stub fetch_mv real RTL simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
    exit 3
  fi
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/decode_stub_fetch_mv_tb_top.sv"
TB="$ROOT/tests/rtl/decode_stub_fetch_mv_tb.cpp"
BUILD="$ROOT/build/verilator/decode_stub_fetch_mv"
BUILD_FAULT="$ROOT/build/verilator/decode_stub_fetch_mv_zero"
PRODUCT_RTL=(
  h264_iq_idct_4x4.sv
  h264_inter_pred.sv
  h264_deblock.sv
  h264_dpb.sv
  decode_stub.sv
  h264_i16_dc_hadamard.sv h264_i16_dc_hadamard_serial.sv h264_dequant4x4_serial.sv
  h264_byte_ram_sp.sv
  h264_i_res_recon_sink.sv
  h264_intra_pred.sv
  h264_recon_frame_store.sv
)

for f in "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
RTL_ARGS=()
for f in "${PRODUCT_RTL[@]}"; do
  if [[ ! -f "$RTL_DIR/$f" ]]; then
    echo "RTL SIM ERROR: missing product RTL: $RTL_DIR/$f" >&2
    exit 2
  fi
  if ! grep -q "rtl/$f" "$QIP"; then
    echo "RTL SIM ERROR: files.qip does not list product RTL: rtl/$f" >&2
    exit 2
  fi
  RTL_ARGS+=("$RTL_DIR/$f")
done

mkdir -p "$BUILD" "$BUILD_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REGISTER: mvd_x=16 qpel → fetch_mv=(16,0) luma_origin_x=4; zero-MV fault RED." >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module decode_stub_fetch_mv_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
"$BUILD/Vdecode_stub_fetch_mv_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module decode_stub_fetch_mv_tb -GFAULT_FORCE_ZERO_FETCH_MV=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
set +e
FAULT_OUT="$("$BUILD_FAULT/Vdecode_stub_fetch_mv_tb" 2>&1)"
FAULT_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" decode_stub_fetch_mv_zero "$FAULT_RC" <<<"$FAULT_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$FAULT_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK decode_stub fetch_mv RTL: nonzero mvd shifted luma origin; zero-MV twin RED"
