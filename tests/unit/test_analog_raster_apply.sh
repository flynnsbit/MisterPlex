#!/usr/bin/env bash
# analogRasterApplyOnStart GREEN + RED twins (swap bits / live apply).
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CXX="${CXX:-g++}"
SRC="$ROOT/tests/unit/test_analog_raster_apply.cpp"
RES="$ROOT/arm/misterplexd/plex_resolve.cpp"
INC="-std=c++17 -O2 -Wall -Wextra -I$ROOT/host -I$ROOT/arm/misterplexd"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

grep -q 'analogRasterApplyOnStart' "$ROOT/arm/misterplexd/main.cpp" || \
  fail "main.cpp must call analogRasterApplyOnStart"
grep -q 'applyAnalogRasterOnStart' "$ROOT/arm/misterplexd/media_player.cpp" || \
  fail "media_player must apply analog raster via setStatusBits"
if grep -q 'OSD_CONTROL=1' "$ROOT/scripts/misterplex_pair_conf.sh"; then
  fail "pair_conf must not ship OSD_CONTROL=1"
else
  ok "pair_conf has no OSD_CONTROL=1"
fi
grep -q 'ANALOG_RASTER=480p31' "$ROOT/scripts/misterplex_pair_conf.sh" || \
  fail "pair_conf default overlay must echo ANALOG_RASTER=480p31"

mkdir -p "$ROOT/build"
green="$ROOT/build/test_analog_raster_apply"
if ! $CXX $INC -o "$green" "$SRC" "$RES"; then
  echo "GREEN compile failed" >&2
  exit 1
fi
if ! "$green"; then
  echo "GREEN run failed" >&2
  exit 1
fi
ok "GREEN analogRasterApplyOnStart rc=0"

red_swap="$ROOT/build/test_analog_raster_apply_red_swap"
if ! $CXX $INC -DANALOG_RASTER_FAULT_SWAP_BITS -o "$red_swap" "$SRC" "$RES"; then
  fail "RED SWAP compile should succeed (runtime must fail)"
else
  set +e
  "$red_swap" >/tmp/analog-raster-red-swap.out 2>/tmp/analog-raster-red-swap.err
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    fail "RED SWAP twin ran rc=0 (480p31 must not encode as bits=1)"
  else
    ok "RED SWAP twin true rc=$rc (480p31 bits != 2)"
  fi
fi

red_live="$ROOT/build/test_analog_raster_apply_red_live"
if ! $CXX $INC -DANALOG_RASTER_FAULT_LIVE_APPLY -o "$red_live" "$SRC" "$RES"; then
  fail "RED LIVE compile should succeed (runtime must fail)"
else
  set +e
  "$red_live" >/tmp/analog-raster-red-live.out 2>/tmp/analog-raster-red-live.err
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    fail "RED LIVE twin ran rc=0 (live OSD rewrite must fail)"
  else
    ok "RED LIVE twin true rc=$rc (applyOnOsdChange must not be true)"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "test_analog_raster_apply.sh: $fails failure(s)" >&2
  exit 1
fi
echo "test_analog_raster_apply.sh: OK"
exit 0
