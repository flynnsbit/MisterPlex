#!/usr/bin/env bash
# LOUD bank-stride overflow guard (w-nostub landmine).
# GREEN: product dual-map + FRAME 1280 with 0x180000 → fault=0, rc=0
# RED:   1280×720 on 512 KiB-only (SOFT) → overflow_fault=1 REPRO_OK
# RED2:  same without SOFT → generate $error must fail compile (rc!=0)
#
# No device. Capture true rc directly (never through a pipe on final status).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
GDIR="$ROOT/build/verilator/bank_stride_green"
FDIR="$ROOT/build/verilator/bank_stride_fault_soft"
HDIR="$ROOT/build/verilator/bank_stride_fault_hard"
mkdir -p "$GDIR" "$FDIR" "$HDIR"

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
echo "RTL SIM: using $VERILATOR_VERSION" >&2

SV_GUARD="$ROOT/fpga/Plex_MiSTer/rtl/ddr_bank_stride_guard.sv"
SV_TB="$ROOT/tests/rtl/ddr_bank_stride_guard_tb.sv"
vflags=(--cc --exe --build --top-module ddr_bank_stride_guard_tb
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
  -CFLAGS "-std=c++17 -O2")

pass=0
fail=0

# --- GREEN: product + optional 720p FRAME with correct 0x180000 ---
echo "=== GREEN product dual-map + 720p FRAME ===" >&2
set +e
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GDIR" \
  -DDDR_BANK_STRIDE_TB_720P_FRAME \
  "$SV_GUARD" "$SV_TB" \
  "$ROOT/tests/rtl/ddr_bank_stride_guard_main.cpp" 2>"$GDIR/build.err"
GRC_BUILD=$?
set -e
if [[ "$GRC_BUILD" -ne 0 ]]; then
  echo "FAIL green build rc=$GRC_BUILD" >&2
  cat "$GDIR/build.err" >&2 || true
  fail=$((fail + 1))
else
  set +e
  GOUT="$("$GDIR/Vddr_bank_stride_guard_tb" 2>&1)"
  GRC=$?
  set -e
  printf '%s\n' "$GOUT"
  if [[ "$GRC" -eq 0 ]] && grep -q "PASS ddr_bank_stride_guard_tb" <<<"$GOUT" \
      && grep -q "PASS_720P_FRAME" <<<"$GOUT"; then
    echo "PASS green rc=$GRC"
    pass=$((pass + 1))
  else
    echo "FAIL green rc=$GRC" >&2
    fail=$((fail + 1))
  fi
fi

# --- RED SOFT: landmine raises overflow_fault without $error kill ---
echo "=== RED SOFT 720p on 512KiB (expect REPRO_OK fault=1) ===" >&2
set +e
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$FDIR" \
  -DDDR_BANK_STRIDE_FAULT_720P_ON_LEGACY \
  -DDDR_BANK_STRIDE_GUARD_SOFT \
  "$SV_GUARD" "$SV_TB" \
  "$ROOT/tests/rtl/ddr_bank_stride_guard_main.cpp" 2>"$FDIR/build.err"
FRC_BUILD=$?
set -e
if [[ "$FRC_BUILD" -ne 0 ]]; then
  echo "FAIL fault-soft build rc=$FRC_BUILD" >&2
  cat "$FDIR/build.err" >&2 || true
  fail=$((fail + 1))
else
  set +e
  FOUT="$("$FDIR/Vddr_bank_stride_guard_tb" 2>&1)"
  FRC=$?
  set -e
  printf '%s\n' "$FOUT"
  if [[ "$FRC" -eq 0 ]] && grep -q "REPRO_OK silent_720p_on_512kib" <<<"$FOUT"; then
    echo "PASS fault-soft REPRO rc=$FRC"
    pass=$((pass + 1))
  else
    echo "FAIL fault-soft rc=$FRC (expected REPRO_OK)" >&2
    fail=$((fail + 1))
  fi
fi

# --- RED HARD: generate $error must fail the build (proof guard can fire) ---
# No -Wno-fatal here — $error must be a hard stop (tautology proof).
echo "=== RED HARD 720p on 512KiB (expect build FAIL / \$error) ===" >&2
hard_flags=(--cc --exe --build --top-module ddr_bank_stride_guard_tb
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
  -CFLAGS "-std=c++17 -O2")
set +e
"$RUN_VERILATOR" "${hard_flags[@]}" --Mdir "$HDIR" \
  -DDDR_BANK_STRIDE_FAULT_720P_ON_LEGACY \
  "$SV_GUARD" "$SV_TB" \
  "$ROOT/tests/rtl/ddr_bank_stride_guard_main.cpp" 2>"$HDIR/build.err"
HRC_BUILD=$?
set -e
if [[ "$HRC_BUILD" -ne 0 ]] && grep -Eiq 'error|overflow|silent|0x180000|bank_stride|%%Error' "$HDIR/build.err"; then
  echo "PASS fault-hard build_rc=$HRC_BUILD (guard \$error fired)"
  pass=$((pass + 1))
  grep -Ei 'error|overflow|silent|stride' "$HDIR/build.err" | head -8 || true
else
  echo "FAIL fault-hard build_rc=$HRC_BUILD — guard did not fail build" >&2
  cat "$HDIR/build.err" >&2 || true
  fail=$((fail + 1))
fi

# Host arithmetic lock (C++ header) — quoted constants
echo "=== Host static arithmetic ===" >&2
HOST_CHK="$ROOT/build/test_ddr_bank_stride_host_arith"
set +e
g++ -std=c++17 -O2 -I"$ROOT/host" -o "$HOST_CHK" -x c++ - <<'CPP'
#include "libmisterplex/ddr_frame_layout.hpp"
#include <cstdio>
int main() {
  using namespace misterplex;
  const unsigned i420 = 1280u * 720u * 3u / 2u;
  static_assert(kPlex720pYuv420pBytes == 1382400, "720p I420");
  static_assert(kPlex720pYuv420pBankStride == 0x00180000u, "Option-C stride");
  static_assert(kPlex480pYuv420pBankStride == 0x00080000u, "LEG stride");
  static_assert(kPlex720pYuv420pBytes > kPlex480pYuv420pBankStride,
                "720p I420 MUST exceed 512KiB stride (landmine class)");
  static_assert(kPlex720pYuv420pBytes <= kPlex720pYuv420pBankUsableBytes,
                "720p I420 fits Option-C usable");
  static_assert(kPlex480pYuv420pBytes <= kPlex480pYuv420pBankUsableBytes,
                "480p I420 fits LEG usable");
  // Map size vs reserved window
  static_assert(kPlex720pDdrFramePhysBase + kPlex720pMapBytes2Bank <=
                    kPlexDdrReservedWindowEnd,
                "2-bank Option-C inside reserved DDR");
  std::printf("HOST_ARITH i420_720=%u leg_stride=0x%x optc_stride=0x%x "
              "ratio=%.3f map2=0x%x window_end=0x%x\n",
              i420, kPlex480pYuv420pBankStride, kPlex720pYuv420pBankStride,
              double(i420) / double(kPlex480pYuv420pBankStride),
              kPlex720pMapBytes2Bank, kPlexDdrReservedWindowEnd);
  // FAULT twin predicate (host): 720p on LEG stride must be rejected by fit check
  const bool landmine = !ddrNativeContentFitsBank(
      makeDdrNativeContentLayout(1280, 720), kPlex480pYuv420pBankStride);
  if (!landmine) {
    std::fprintf(stderr, "FAIL host landmine predicate\n");
    return 1;
  }
  std::printf("HOST_LANDMINE_REJECT 1280x720 vs 0x80000 OK\n");
  std::printf("PASS host bank stride arith\n");
  return 0;
}
CPP
HRC=$?
set -e
if [[ "$HRC" -ne 0 ]]; then
  echo "FAIL host arith compile/link rc=$HRC" >&2
  fail=$((fail + 1))
else
  set +e
  "$HOST_CHK"
  HRC2=$?
  set -e
  if [[ "$HRC2" -eq 0 ]]; then
    echo "PASS host arith rc=0"
    pass=$((pass + 1))
  else
    echo "FAIL host arith run rc=$HRC2" >&2
    fail=$((fail + 1))
  fi
fi

echo "SUMMARY pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "DDR_BANK_STRIDE_GUARD_FAIL fail=$fail"
  exit 1
fi
if [[ "$pass" -lt 4 ]]; then
  echo "DDR_BANK_STRIDE_GUARD_FAIL pass=$pass too few" >&2
  exit 1
fi
echo "DDR_BANK_STRIDE_GUARD_OK pass=$pass"
exit 0
