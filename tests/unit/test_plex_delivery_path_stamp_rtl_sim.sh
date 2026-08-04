#!/usr/bin/env bash
# Verilator sim for plex_delivery_path_stamp — default ARM_COPY + FABRIC_DMA twin.
# Soft-skip≠PASS. true rc direct (never through a pipe on the final status).
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: sim did not EXECUTE expected marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only or empty run is not a pass" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/plex_delivery_path_stamp.sv"
TOP="$ROOT/tests/rtl/plex_delivery_path_stamp_tb_top.sv"
TB="$ROOT/tests/rtl/plex_delivery_path_stamp_tb.cpp"

echo "=== test_plex_delivery_path_stamp_rtl_sim EXECUTED ==="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP-NOT-PASS RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_and_run() {
  local label="$1"
  local vl_defs="$2"
  local c_defs="$3"
  local mdir="$ROOT/build/verilator/plex_delivery_path_stamp_${label}"
  mkdir -p "$mdir"
  # shellcheck disable=SC2086
  set +e
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$mdir" \
    --top-module plex_delivery_path_stamp_tb_top \
    -Wno-fatal \
    $vl_defs \
    -CFLAGS "-std=c++17 -O2 ${c_defs}" \
    "$TOP" "$RTL" "$TB"
  local v_rc=$?
  set -e
  echo "verilator_build_${label} true rc=$v_rc"
  if [[ "$v_rc" -ne 0 ]]; then
    return "$v_rc"
  fi
  local bin="$mdir/Vplex_delivery_path_stamp_tb_top"
  [[ -x "$bin" ]] || bin="${bin}.exe"
  set +e
  local out rc
  out=$("$bin" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "sim_${label} true rc=$rc"
  printf '%s\n' "$out" >"$mdir/run.out"
  return "$rc"
}

echo "=== GREEN default ARM_COPY ==="
set +e
build_and_run green "" ""
g_rc=$?
set -e
g_out=$(cat "$ROOT/build/verilator/plex_delivery_path_stamp_green/run.out")
assert_sim_executed "default_arm" "$g_out" \
  "CASE EXECUTED" "PASS DEFAULT_ARM_COPY" "PASS plex_delivery_path_stamp_tb"
[[ "$g_rc" -eq 0 ]] || { echo "FAIL green true rc=$g_rc" >&2; exit "$g_rc"; }

echo "=== GREEN FABRIC_FRAME_DMA claim ==="
set +e
build_and_run fabric "-DFABRIC_FRAME_DMA" "-DEXPECT_FABRIC_DMA"
f_rc=$?
set -e
f_out=$(cat "$ROOT/build/verilator/plex_delivery_path_stamp_fabric/run.out")
assert_sim_executed "fabric_dma" "$f_out" \
  "CASE EXECUTED" "PASS EXPECT_FABRIC_DMA" "PASS plex_delivery_path_stamp_tb"
[[ "$f_rc" -eq 0 ]] || { echo "FAIL fabric true rc=$f_rc" >&2; exit "$f_rc"; }

echo "EXECUTED delivery_path_stamp GREEN_arm_rc=0 GREEN_fabric_rc=0"
echo "PASS test_plex_delivery_path_stamp_rtl_sim"
echo "true rc=0"
exit 0
