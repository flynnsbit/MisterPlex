#!/usr/bin/env bash
# Product HIT_SCAN=48 pre-fit cap (rd-duck). Storage MAX_CMDS stays 112.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL $*" >&2; exit 1; }

# RTL default
grep -q 'parameter int HIT_SCAN = 48' "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv" \
  || fail "RTL HIT_SCAN default != 48"
grep -q 'parameter int MAX_CMDS = 112' "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv" \
  || fail "RTL MAX_CMDS default != 112"

# Product instance
grep -n 'HIT_SCAN(48)' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v" | grep -q plex_chrome \
  || grep -A3 'plex_chrome #(' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v" | grep -q 'HIT_SCAN(48)' \
  || fail "sys_top product HIT_SCAN != 48"
grep -A5 'plex_chrome #(' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v" | grep -q 'MAX_CMDS(112)' \
  || fail "sys_top product MAX_CMDS != 112"

# Host constants
grep -q 'kHitScan = 48' "$ROOT/host/libmisterplex/plex_chrome_cmds.hpp" \
  || fail "kHitScan != 48"
grep -q 'kMaxCmds = 112' "$ROOT/host/libmisterplex/plex_chrome_cmds.hpp" \
  || fail "kMaxCmds != 112"

# Must not re-arm HIT_SCAN=112 on product sys_top
if grep -A6 'plex_chrome #(' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v" | grep -q 'HIT_SCAN(112)'; then
  fail "sys_top still has HIT_SCAN(112)"
fi

echo "test_plex_chrome_hit_scan_static: PASS"
exit 0
