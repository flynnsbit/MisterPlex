#!/usr/bin/env bash
# Verilator gate: present_content_window NN map — RED fault / GREEN positive.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv"
TOP="$ROOT/tests/rtl/present_content_window_tb_top.sv"
TB="$ROOT/tests/rtl/present_content_window_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; content_window RTL sim NOT run." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    exit 3
  fi
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_one() {
  local name="$1"
  local vdef="$2"
  local cdef="$3"
  local build_dir="$ROOT/build/verilator/$name"
  mkdir -p "$build_dir"
  echo "RTL SIM: $VERILATOR_VERSION ($name)" >&2
  # shellcheck disable=SC2086
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module present_content_window_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2 ${cdef}" \
    ${vdef} \
    "$RTL" "$TOP" "$TB"
}

# RED: floor-scale fault must diverge (exe returns non-zero)
build_one present_content_window_neg -DPRESENT_WINDOW_FAULT_FLOOR_SCALE '-DPRESENT_WINDOW_FAULT_FLOOR_SCALE'
NEG_EXE="$ROOT/build/verilator/present_content_window_neg/Vpresent_content_window_tb_top"
set +e
"$NEG_EXE" > "$ROOT/build/present_content_window_negative.log" 2>&1
NEG_RC=$?
set -e
if [[ "$NEG_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: FLOOR_SCALE fault unexpectedly matched reference" >&2
  cat "$ROOT/build/present_content_window_negative.log" >&2
  exit 1
fi
echo "RTL SIM RED proof: FLOOR_SCALE diverged (rc=$NEG_RC)" >&2
sed -n '1,12p' "$ROOT/build/present_content_window_negative.log" >&2

build_one present_content_window_pos '' ''
POS_EXE="$ROOT/build/verilator/present_content_window_pos/Vpresent_content_window_tb_top"
# shellcheck source=tests/unit/lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
set +e
POS_OUT="$("$POS_EXE" 2>&1)"
POS_RC=$?
set -e
printf '%s\n' "$POS_OUT"
echo "present_content_window_pos true rc=$POS_RC"
if [[ "$POS_RC" -ne 0 ]]; then
  exit "$POS_RC"
fi
assert_sim_executed "present_content_window_pos" "$POS_OUT" "Verilator PASS"
echo "present_content_window Verilator PASS"
