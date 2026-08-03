#!/usr/bin/env bash
# Source greps proving present_cadence is unwired from DDR swap (C1).
# Soft-skip never. COMPILE/logic fails are RED.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0

check() {
  local label="$1"
  local file="$2"
  local pat="$3"
  if ! grep -nE -- "$pat" "$file" >/dev/null; then
    echo "FAIL C1: $label — pattern not found in $file: $pat" >&2
    FAIL=1
  else
    echo "OK C1: $label"
    grep -nE -- "$pat" "$file" | head -3
  fi
}

check_absent_in_swap() {
  # ddr_frame_store swap block must not mention cadence/advance_unique
  if grep -nE 'advance_unique|present_cadence|content_fps' \
      "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" | grep -i swap >/dev/null 2>&1; then
    echo "FAIL C1: cadence symbol near swap in ddr_frame_store" >&2
    FAIL=1
  else
    echo "OK C1: no cadence symbols driving ddr_frame_store.sv"
  fi
}

echo "=== C1 source path: cadence vs swap ==="
check "present_cadence instantiated" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" \
  'present_cadence[[:space:]]+cadence'
check "advance is only stat_advance assign" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" \
  'assign[[:space:]]+stat_advance[[:space:]]*=[[:space:]]*advance'
check "ddr swap condition" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  'vsync_pulse && swap_pending && pending_ready_s2'
check "vsync_pulse from fstart" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" \
  'vsync_pulse\(fstart\)'
check "advance tied unused at top" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  '_unused = \|\{[^}]*advance'
# B15 + ABI#2: q5 fps_valid/content_fps consumer (no hardwired 24/30 freeze)
check "B15 runtime content_fps banner" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  'B15 \+ parent ABI arbitration #2|content_fps from PLXG q5'
check "B15 plex_content_fps_sel" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  'plex_content_fps_sel'
check "B15 fps_valid consumer" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv" \
  'fps_valid'
if grep -nE "content_fps_idle.*=.*8'd30|content_fps = 8'd30" "$ROOT/fpga/Plex_MiSTer/Plex.sv"; then
  echo "FAIL C1/B15: invent hardcode 30 in Plex" >&2
  FAIL=1
else
  echo "OK C1/B15: no invented hardcode 30"
fi
if grep -nE "wire \[7:0\] content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  | grep -v FAULT_B15 >/dev/null 2>&1; then
  if ! grep -B3 -E "content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
      | grep -q FAULT_B15_FPS_HARDWIRE_24; then
    echo "FAIL C1/B15: content_fps hardwired 24 outside FAULT" >&2
    FAIL=1
  else
    echo "OK C1/B15: hardwired 24 only under FAULT red twin"
  fi
else
  echo "OK C1/B15: no product hardwired content_fps=24"
fi

# present-swap cadence.hpp must not be included from arm/ (test-only product path).
# Do NOT match plxg_q5_aspect_cadence.hpp — that is ABI#2 PLXG q5 packing (allowed).
if grep -rn --include='*.cpp' --include='*.hpp' 'libmisterplex/cadence.hpp' "$ROOT/arm" >/dev/null 2>&1; then
  echo "FAIL C1: libmisterplex/cadence.hpp referenced from arm/" >&2
  grep -rn --include='*.cpp' --include='*.hpp' 'libmisterplex/cadence.hpp' "$ROOT/arm" >&2 || true
  FAIL=1
else
  echo "OK C1: libmisterplex/cadence.hpp not referenced from arm/"
fi

# bank_vsync_count not in PLXD pack (fabric hist limitation)
if grep -n 'bank_vsync_count' "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" | head -5; then
  if grep -n 'frames_done_d2' "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" | head -3; then
    echo "OK C1: frames_done packed; bank_vsync_count exists (must not be PLXD frames field)"
  fi
fi
if grep -nE 'DDRAM_DIN <= \{bank_vsync_count' "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"; then
  echo "FAIL C1: bank_vsync_count unexpectedly packed as PLXD word" >&2
  FAIL=1
else
  echo "OK C1: bank_vsync_count not packed into PLXD DIN"
fi

check_absent_in_swap

# Build+run model gate
mkdir -p "$ROOT/build"
set +e
"$ROOT/build/test_cadence_swap_path" >/dev/null 2>&1
NEED_BUILD=$?
set -e
if [[ ! -x "$ROOT/build/test_cadence_swap_path" || "$NEED_BUILD" -ne 0 ]]; then
  g++ -std=c++17 -O2 -I"$ROOT/host" -o "$ROOT/build/test_cadence_swap_path" \
    "$ROOT/tests/unit/test_cadence_swap_path.cpp"
fi
set +e
OUT="$("$ROOT/build/test_cadence_swap_path" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "test_cadence_swap_path true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL: test_cadence_swap_path rc=$RC" >&2
  exit "$RC"
fi
if ! grep -q 'OK test_cadence_swap_path' <<<"$OUT"; then
  echo "FAIL: missing OK marker" >&2
  exit 2
fi
if ! grep -q 'PRE-REGISTER publish_interval' <<<"$OUT"; then
  echo "FAIL: pre-register not printed before compute" >&2
  exit 2
fi
if ! grep -q 'INVALIDATED: fabric hold via frames_done' <<<"$OUT"; then
  echo "FAIL: missing frames_done hold INVALIDATED note" >&2
  exit 2
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL test_cadence_swap_path_source" >&2
  exit 1
fi
echo "OK test_cadence_swap_path_source: C1 greps + model gate rc=0"
exit 0
