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
# Template path: vsync_pulse(fstart). MULTI path: .vsync_pulse(fs_vsync_w)
# with fs_vsync_w = fstart or mp_fstart (clock integ).
if grep -nE 'vsync_pulse\(fstart\)' "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" >/dev/null \
  || { grep -nE '\.vsync_pulse\(fs_vsync_w\)' "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" >/dev/null \
       && grep -nE 'assign[[:space:]]+fs_vsync_w[[:space:]]*=' "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" >/dev/null; }; then
  echo "OK C1: vsync_pulse from fstart/fs_vsync_w (MULTI-aware)"
else
  echo "FAIL C1: vsync_pulse source not fstart or fs_vsync_w" >&2
  FAIL=1
fi
check "advance tied unused at top" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  '_unused = \|\{[^}]*advance'
check "daemon paces content comment" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  'daemon handles exact content pacing'
check "content_fps hardwired 24" \
  "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  'content_fps = 8.d24|content_fps = 8'\''d24'

# cadence.hpp not included from arm/
if grep -rn --include='*.cpp' --include='*.hpp' 'cadence.hpp' "$ROOT/arm" >/dev/null 2>&1; then
  echo "FAIL C1: cadence.hpp referenced from arm/" >&2
  grep -rn --include='*.cpp' --include='*.hpp' 'cadence.hpp' "$ROOT/arm" >&2 || true
  FAIL=1
else
  echo "OK C1: cadence.hpp not referenced from arm/"
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
