#!/usr/bin/env bash
# Gate: PPC2 dual-lane distinct PASS + scalar-replicate NEG FAIL (rd-duck).
# Beat-delta bus TB is NOT this gate — it is refill-demand only (scalar-identical).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VERILATOR_RC" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_one() {
  local name="$1" top_sv="$2" top_mod="$3"
  local BUILD="$ROOT/build/verilator/$name"
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$BUILD" \
    --top-module "$top_mod" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "-std=c++17 -O2" \
    +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
    "$top_sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
    "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb.cpp"
  local EXE="$BUILD/V${top_mod}"
  if [[ ! -x "$EXE" ]]; then
    echo "FAIL $name: binary missing" >&2
    return 2
  fi
  # C++ includes Vddr_frame_store_ppc2_distinct_tb.h — only works for that top name.
  # For scalar_neg we need matching module name OR shared header trick.
  echo "$EXE"
}

echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REG: PPC2 gradient lanes differ PASS; scalar {r,r} replicate FAIL"

# --- PPC2 positive ---
BUILD_P2="$ROOT/build/verilator/ddr_frame_store_ppc2_distinct"
rm -rf "$BUILD_P2" && mkdir -p "$BUILD_P2"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_P2" \
  --top-module ddr_frame_store_ppc2_distinct_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb.cpp"
EXE_P2="$BUILD_P2/Vddr_frame_store_ppc2_distinct_tb"
set +e
OUT_P2="$("$EXE_P2" 2>&1)"
RC_P2=$?
set -e
printf '%s\n' "$OUT_P2"
echo "$OUT_P2" | grep -q PASS || { echo "FAIL ppc2_distinct positive: no PASS" >&2; exit 1; }
[[ "$RC_P2" -eq 0 ]] || { echo "FAIL ppc2_distinct positive rc=$RC_P2" >&2; exit "$RC_P2"; }
echo "PASS ppc2_distinct positive true rc=0"

# --- SCALAR NEG: same C++ checker against {r,r} pad top ---
# Rebuild C++ against scalar top by aliasing module name via wrapper include.
BUILD_S="$ROOT/build/verilator/ddr_frame_store_scalar_neg"
rm -rf "$BUILD_S" && mkdir -p "$BUILD_S"
# Copy cpp with include rename so Verilator generates Vddr_frame_store_scalar_neg_tb.h
CPP_S="$BUILD_S/tb.cpp"
sed 's/Vddr_frame_store_ppc2_distinct_tb/Vddr_frame_store_scalar_neg_tb/g' \
  "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb.cpp" > "$CPP_S"
# Force expect-fail mode via define
sed -i '1i#define SCALAR_NEG_EXPECT_EQUAL 1' "$CPP_S"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_S" \
  --top-module ddr_frame_store_scalar_neg_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2 -DSCALAR_NEG_EXPECT_EQUAL=1" \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/ddr_frame_store_scalar_neg_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$CPP_S"

EXE_S="$BUILD_S/Vddr_frame_store_scalar_neg_tb"
set +e
OUT_S="$("$EXE_S" 2>&1)"
RC_S=$?
set -e
printf '%s\n' "$OUT_S"
# NEG must NOT pass the distinct criteria (rc!=0 or no PASS / EQUAL fail)
if echo "$OUT_S" | grep -q "PASS ppc2_distinct"; then
  echo "FAIL scalar_neg: distinct gate incorrectly PASSed on {r,r} replicate" >&2
  exit 1
fi
if [[ "$RC_S" -eq 0 ]]; then
  echo "FAIL scalar_neg: rc=0 on scalar replicate (gate does not discriminate)" >&2
  exit 1
fi
echo "PASS scalar_neg discrimination: distinct gate RED on scalar (rc=$RC_S)"
echo "NOTE: bus beat-delta is refill-demand only; scalar G0/G1 counts match PPC2 — not PPC2 closed"
echo "ddr_frame_store_ppc2_distinct+scalar_neg true rc=0"
exit 0
