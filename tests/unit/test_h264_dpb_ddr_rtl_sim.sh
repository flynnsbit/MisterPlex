#!/usr/bin/env bash
# DDR-resident DPB: slot mgr + byte bridge + ref window cache.
# Positive build must PASS. Fault twins must detect the injected bug (rc=0 on twin).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP RTL SIM: Verilator not found; h264_dpb_ddr was NOT run." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without sim." >&2
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
TOP="$ROOT/tests/rtl/h264_dpb_ddr_tb_top.sv"
TB="$ROOT/tests/rtl/h264_dpb_ddr_tb.cpp"
BUILD="$ROOT/build/verilator/h264_dpb_ddr"
BUILD_EVICT="$ROOT/build/verilator/h264_dpb_ddr_fault_evict"
BUILD_SMALL="$ROOT/build/verilator/h264_dpb_ddr_fault_small"

SV=(
  "$TOP"
  "$RTL_DIR/h264_dpb_slot_mgr.sv"
  "$RTL_DIR/h264_dpb_ddr_byte_bridge.sv"
  "$RTL_DIR/h264_dpb_ref_win_cache.sv"
  "$TB"
)

for f in "${SV[@]}" "$QIP"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing $f" >&2
    exit 2
  fi
done
for needle in h264_dpb_slot_mgr.sv h264_dpb_ddr_byte_bridge.sv h264_dpb_ref_win_cache.sv; do
  if ! grep -q "$needle" "$QIP"; then
    echo "RTL SIM ERROR: files.qip missing $needle" >&2
    exit 2
  fi
done

run_one() {
  local build_dir="$1"
  shift
  local defines=("$@")
  mkdir -p "$build_dir"
  local args=(
    --cc --exe --build -j 0
    -Mdir "$build_dir"
    --top-module h264_dpb_ddr_tb_top
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
    -CFLAGS "-std=c++17"
  )
  local d
  for d in "${defines[@]+"${defines[@]}"}"; do
    [[ -n "$d" ]] && args+=(-CFLAGS "-D$d" -D"$d")
  done
  args+=("${SV[@]}")
  echo "+ $RUN_VERILATOR ${args[*]}"
  "$RUN_VERILATOR" "${args[@]}"
  echo "+ $build_dir/Vh264_dpb_ddr_tb_top"
  "$build_dir/Vh264_dpb_ddr_tb_top"
}

echo "=== POSITIVE h264_dpb_ddr ==="
run_one "$BUILD"
echo "POSITIVE_CONCLUSION=PASS"

echo "=== NEGATIVE twin: WRONG_EVICT ==="
run_one "$BUILD_EVICT" "H264_DPB_DDR_FAULT_WRONG_EVICT"
echo "NEGATIVE_EVICT_CONCLUSION=PASS"

echo "=== NEGATIVE twin: SMALL_WIN ==="
run_one "$BUILD_SMALL" "H264_DPB_DDR_FAULT_SMALL_WIN"
echo "NEGATIVE_SMALL_WIN_CONCLUSION=PASS"

echo "h264_dpb_ddr RTL sim: all conclusions PASS"
exit 0
