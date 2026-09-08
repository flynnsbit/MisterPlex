#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOCK_DEFINES=()
case "${CLOCK_PROFILE:?Select control20 or sys120 explicitly}" in
  control20) SYS_MHZ=20 ;;
  sys120) SYS_MHZ=120; CLOCK_DEFINES=(-DPLEX_CLK_SYS_120=1) ;;
  *) printf 'Unsupported clock profile: %s\n' "$CLOCK_PROFILE" >&2; exit 2 ;;
esac
SYS_PERIOD=$((720 / SYS_MHZ))
if (($# == 0)); then set -- default; fi
for MODE in "$@"; do
LIMIT=8192
STATIC_IDR=1
FILTER=0
INJECT=0
ACTIVE_FAULT=0
TIMING=1
JOINT=0
FRAMES=2
PLANES=1
CASES=(pms139 pms146)
EXTRA=()
case "$MODE" in
  default) ;;
  legacy-default) PLANES=0 ;;
  ingress-seek) CASES=(pms146); EXTRA=(128 truncated ingress-seek) ;;
  large-au) LIMIT=32768; CASES=(pms146); EXTRA=(128 truncated large-au) ;;
  vcl-overflow) LIMIT=32768; CASES=(pms146); EXTRA=(128 vcl-overflow) ;;
  fault-recovery) CASES=(pms146); EXTRA=(128 truncated fault-recovery) ;;
  fault21-recovery)
    FILTER=1; INJECT=1; CASES=(pms146); EXTRA=(128 filter-metadata fault-recovery) ;;
  joint-filter)
    STATIC_IDR=0; FILTER=1; TIMING=0; JOINT=1; CASES=(feature-textured-pair) ;;
  full240-joint)
    STATIC_IDR=0; FILTER=1; TIMING=0; JOINT=1; FRAMES=3; CASES=(feature-full240-3) ;;
  legacy-full240)
    PLANES=0; STATIC_IDR=0; FILTER=1; TIMING=0; JOINT=1; FRAMES=3; CASES=(feature-full240-3) ;;
  color-gop12)
    STATIC_IDR=0; FILTER=1; TIMING=0; JOINT=1; FRAMES=12; CASES=(color-gop12-320x240) ;;
  active-filter-recovery)
    STATIC_IDR=0; FILTER=1; TIMING=0; JOINT=1; FRAMES=3; ACTIVE_FAULT=1
    CASES=(feature-full240-3); EXTRA=(128 active-filter fault-recovery) ;;
  *) printf 'Unknown frozen ingress mode: %s\n' "$MODE" >&2; exit 2 ;;
esac
for fixture in "${CASES[@]}"; do
  if [[ ! -d "$ROOT/tests/fixtures/$fixture" ]]; then
    printf 'Missing prepared fixture %s; use run_integration.py --prepare-publisher-pair first\n' "$fixture" >&2
    exit 2
  fi
done
if ps -eo comm= | grep -qE '^quartus_(fit|map|sta|sh)$'; then
  printf 'FIT_ACTIVE: ingress simulation deferred\n' >&2
  exit 75
fi
BUILD="$ROOT/build/verilator/clock_${CLOCK_PROFILE}_${LIMIT}_${STATIC_IDR}_${FILTER}_${INJECT}_${TIMING}_${FRAMES}_${ACTIVE_FAULT}_planes${PLANES}"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
exec 9>"$BUILD/build.lock"
flock 9
printf '{"profile":"%s","SYS_MHz":%s,"DDR_MHz":90,"base_Hz":720000000,"SYS_period":%s,"DDR_period":8,"rising_phase_ticks":0,"event_budget_seconds":1,"SYNC_MB_PLANES":%s}\n' \
  "$CLOCK_PROFILE" "$SYS_MHZ" "$SYS_PERIOD" "$PLANES" > "$BUILD/clock-binding.json"
SOURCES=()
while read -r command option kind source; do
  if [[ "$command" == set_global_assignment && "$kind" == SYSTEMVERILOG_FILE &&
        "$source" == rtl/* ]]; then
    SOURCES+=("$ROOT/fpga/Plex_MiSTer/$source")
  fi
done < "$ROOT/fpga/Plex_MiSTer/files.qip"
FIXTURE_INPUTS=()
for fixture in "${CASES[@]}"; do FIXTURE_INPUTS+=("$ROOT/tests/fixtures/$fixture/"*); done
sha256sum "$BUILD/clock-binding.json" "$ROOT/tests/unit/test_ingress_frozen_pair.sh" "$ROOT/scripts/run_verilator.sh" \
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv" \
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp" "${SOURCES[@]}" \
  "$ROOT"/fpga/Plex_MiSTer/rtl/*.svh "$ROOT"/tests/frozen-host/*.hpp \
  "${FIXTURE_INPUTS[@]}" > "$BUILD/inputs.sha256"
bash "$ROOT/scripts/run_verilator.sh" --cc --exe --build --assert -j 1 \
  --Mdir "$BUILD" --top-module fpga_video_publish_tb -Wno-fatal \
  -GINTEGRATE_STREAM=1 -GIDR_ONLY_PROFILE="$STATIC_IDR" -GMAX_AU_BYTES="$LIMIT" \
  -GENABLE_FRAME_DEBLOCK="$FILTER" -GTEST_FILTER_METADATA_FAULT="$INJECT" \
  -GSYNC_MB_PLANES="$PLANES" \
  -GTEST_ACTIVE_FILTER_FAULT="$ACTIVE_FAULT" \
  -GNATIVE_BEAM=1 -GNATIVE_SCANDOUBLE=1 -DFULL_AU_RTL=1 -DDDR_FRAME_STORE=1 \
  -DCAVLC_WINDOW_BYTES=8 -DCAVLC_LEVEL_LANES=1 \
  "${CLOCK_DEFINES[@]}" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2 -DSIM_SYS_MHZ=$SYS_MHZ -DFULL_AU=1 -DFULL_AU_FRAMES=$FRAMES -DFULL_AU_ORIGINAL_TIMING=$TIMING -DFULL_AU_JOINT_FILTER=$JOINT -DFULL_AU_RUNTIME_GEOMETRY=1 -DFULL_AU_NATIVE_BEAM=1 -DFULL_AU_SCANDOUBLE=1 -I$ROOT/tests/frozen-host" \
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv" "${SOURCES[@]}" \
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp" > "$BUILD/build.log" 2>&1 || {
    tail -60 "$BUILD/build.log"
    exit 1
  }
sha256sum "$BUILD/Vfpga_video_publish_tb" > "$BUILD/binary.sha256"
for fixture in "${CASES[@]}"; do
  OUT="$BUILD/$MODE/$fixture"
  mkdir -p "$OUT"
  cp "$BUILD/clock-binding.json" "$BUILD/inputs.sha256" "$BUILD/binary.sha256" "$OUT/"
  "$BUILD/Vfpga_video_publish_tb" "$ROOT/tests/fixtures/$fixture" \
    "$OUT/actual.i420" "${EXTRA[@]}" > "$OUT/execution.log" 2>&1 || {
      tail -60 "$OUT/execution.log"
      exit 1
    }
  cmp "$OUT/actual.i420" "$ROOT/tests/fixtures/$fixture/reference.yuv"
  sha256sum "$OUT/actual.i420" > "$OUT/actual.sha256"
  grep -E 'METRIC|LEGACY_RGB_PASS|BANK_REUSE_PASS|FILTER_ACTIVE_FAULT|FILTER_METADATA_FAULT|FAULT_RECOVERY_PASS|CODEC_ERROR_PASS|INGRESS_SEEK_PASS|LARGE_AU_PASS|VCL_REJECT|FRAME_PASS|NATIVE_PASS|PASS ' "$OUT/execution.log"
done
sha256sum --check --status "$BUILD/inputs.sha256"
done
