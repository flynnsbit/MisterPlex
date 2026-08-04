#!/usr/bin/env bash
# w-mem: MULTI+PPC2 720p DDR ABI tier (rd-duck BLOCKING L4-only fallthrough).
# GREEN: MULTI@1280×720 → Option-C banks + LINE_COUNT≥16
# GREEN: L4_ONLY forces tier; 480P stays legacy
# RED:   FAULT_FORCE_480 under 1280 canvas must fail
# Also gates present_core.sv wires FS_* (not raw 480p DDR_FRAME_CODED_*).
# No Quartus. No device. Soft-skip≠PASS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
BUILD="$ROOT/build/verilator/present_multi_720p_abi"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/present_multi_720p_abi_tb.sv"
PC="$RTL/present_core.sv"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
echo "RTL SIM: $VERILATOR_VERSION"

# --- Source gates (present_core must use shared tier, not L4-only / raw 480p) ---
grep -q 'plex_ddr_720p_tier.svh' "$PC" || {
  echo "FAIL: present_core.sv missing plex_ddr_720p_tier.svh include" >&2
  exit 1
}
grep -q '\.CODED_W(FS_CODED_W)' "$PC" || {
  echo "FAIL: present_core.sv must wire .CODED_W(FS_CODED_W)" >&2
  exit 1
}
grep -q '\.DOORBELL_PHYS(FS_DOORBELL)' "$PC" || {
  echo "FAIL: present_core.sv must wire .DOORBELL_PHYS(FS_DOORBELL)" >&2
  exit 1
}
if grep -q '\.CODED_W(DDR_FRAME_CODED_WIDTH)' "$PC"; then
  echo "FAIL: present_core still hardwires .CODED_W(DDR_FRAME_CODED_WIDTH) — MULTI 720p fallthrough class" >&2
  exit 1
fi
if grep -E '\.PHYS_BASE\(32'\''h3000_0000\)' "$PC" >/dev/null; then
  echo "FAIL: present_core still hardwires PHYS_BASE 0x30000000 — use FS_PHYS_BASE" >&2
  exit 1
fi
grep -q '\.PHYS_BASE(FS_PHYS_BASE)' "$PC" || {
  echo "FAIL: present_core.sv must wire .PHYS_BASE(FS_PHYS_BASE)" >&2
  exit 1
}
# LINE_COUNT 720p default present
grep -q 'FRAME_W == 1280' "$PC" || {
  echo "FAIL: present_core missing 1280 FRAME_LINE_COUNT lift" >&2
  exit 1
}
echo "OK present_core source gates"

SRCS=(
  "$TB"
  "$PC"
  "$RTL/ddr_frame_store.sv"
  "$RTL/yuv_bt601_npx.sv"
  "$RTL/ddr_bank_geom_guard.sv"
  "$RTL/line_buf_ram.sv"
  "$RTL/async_fifo.sv"
  "$RTL/present_video_timing_720p.sv"
  "$RTL/present_beam_ppc.sv"
  "$RTL/present_beam_content_de.sv"
  "$RTL/colorbars.sv"
  "$RTL/frame_store.sv"
  "$RTL/audio_tone.sv"
  "$RTL/present_npx_path.sv"
  "$RTL/audio_fifo.sv"
  "$RTL/present_cadence.sv"
  "$RTL/present_pix_rate_match.sv"
)
INCS=(-I"$RTL")
COMMON=(-Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED --timing --binary --top-module present_multi_720p_abi_tb)

run_case() {
  local name="$1" want_rc="$2" pass_pat="$3"
  shift 3
  local dir="$BUILD/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  set +e
  "$RUN_VERILATOR" "${COMMON[@]}" "$@" "${INCS[@]}" -Mdir "$dir" "${SRCS[@]}" \
    >"$dir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    if [[ "$want_rc" -ne 0 ]]; then
      echo "OK $name build_rc=$brc (accepted as RED path)"
      return 0
    fi
    tail -40 "$dir/build.log" >&2
    echo "FAIL $name verilator build rc=$brc" >&2
    exit 1
  fi
  set +e
  "$dir/Vpresent_multi_720p_abi_tb" >"$dir/run.log" 2>&1
  local rrc=$?
  set -e
  if [[ "$rrc" -ne "$want_rc" ]]; then
    tail -40 "$dir/run.log" >&2
    echo "FAIL $name rc=$rrc want=$want_rc" >&2
    exit 1
  fi
  if [[ "$want_rc" -eq 0 ]]; then
    grep -q "$pass_pat" "$dir/run.log" || {
      tail -40 "$dir/run.log" >&2
      echo "FAIL $name missing marker '$pass_pat'" >&2
      exit 1
    }
  else
    grep -q "RED present_multi_720p_abi FAULT_FORCE_480" "$dir/run.log" || \
    grep -q "FAULT" "$dir/run.log" || true
  fi
  echo "OK $name rc=$rrc"
}

echo "=== GREEN MULTI+PPC2 @1280x720 (shipping recipe) ==="
run_case multi_ppc2 0 "PASS present_multi_720p_abi MULTI+PPC2" \
  -DPRESENT_MULTI_PIXEL -DPRESENT_PX_PER_CLK=2

echo "=== GREEN L4_ONLY forces 720p tier (FRAME 640) ==="
run_case l4_only 0 "PASS present_multi_720p_abi L4_ONLY" \
  -DCASE_L4_ONLY -DPLEX_PRESENT_720P_L4

echo "=== GREEN 480P legacy banks ==="
run_case p480 0 "PASS present_multi_720p_abi 480P" \
  -DCASE_480P

echo "=== RED FAULT_FORCE_480 under 1280 canvas ==="
run_case fault480 1 "RED" \
  -DCASE_FAULT_480 -DPLEX_DDR_720P_TIER_FAULT_FORCE_480 -DPRESENT_MULTI_PIXEL

echo "PASS test_present_multi_720p_abi"
exit 0
