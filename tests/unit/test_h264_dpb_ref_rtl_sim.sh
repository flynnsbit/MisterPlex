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
SKIP RTL SIM: Verilator not found; h264_dpb_ref real RTL simulation was NOT run.
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ref.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_dpb_ref_tb_top.sv"
TB="$ROOT/tests/rtl/h264_dpb_ref_tb.cpp"
FIX="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264"
BUILD="$ROOT/build/verilator/h264_dpb_ref"
BUILD_CLAMP_FAULT="$ROOT/build/verilator/h264_dpb_ref_clamp_fault"
BUILD_V_FAULT="$ROOT/build/verilator/h264_dpb_ref_v_fault"

for f in "$RTL" "$QIP" "$TOP" "$TB" "$FIX"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_dpb_ref.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_dpb_ref.sv product RTL" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_CLAMP_FAULT" "$BUILD_V_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_dpb_ref_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_dpb_ref_tb_top"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_CLAMP_FAULT" \
  --top-module h264_dpb_ref_tb_top -GFAULT_NO_EDGE_CLAMP=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
FAULT_OUT="$("$BUILD_CLAMP_FAULT/Vh264_dpb_ref_tb_top" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]] || ! grep -q 'edge clamp' <<<"$FAULT_OUT"; then
  echo "FAIL h264_dpb_ref red-check: unclamped edge fault did not fail edge clamp evidence" >&2
  exit 1
fi

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_V_FAULT" \
  --top-module h264_dpb_ref_tb_top -GFAULT_V_OFFSET_U=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
FAULT_OUT="$("$BUILD_V_FAULT/Vh264_dpb_ref_tb_top" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]] || ! grep -q 'plane=2' <<<"$FAULT_OUT"; then
  echo "FAIL h264_dpb_ref red-check: V-plane offset fault did not fail V plane evidence" >&2
  exit 1
fi
echo "OK h264_dpb_ref red-checks: edge clamp and V-plane offset faults failed"
