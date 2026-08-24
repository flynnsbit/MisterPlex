#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_cabac simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

TOP="$ROOT/tests/rtl/h264_cabac_tb.sv"
TB="$ROOT/tests/rtl/h264_cabac_tb.cpp"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cabac.sv"
BUILD="$ROOT/build/verilator/h264_cabac"
BUILD_RENORM="$ROOT/build/verilator/h264_cabac_skip_renorm"
BUILD_INIT="$ROOT/build/verilator/h264_cabac_bad_init"
for f in "$TOP" "$TB" "$RTL"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_cabac.sv' "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "RTL SIM ERROR: files.qip does not list rtl/h264_cabac.sv" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_RENORM" "$BUILD_INIT"
echo "RTL SIM: using $VERILATOR_VERSION (h264_cabac)" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_cabac_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_cabac_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_RENORM" \
  --top-module h264_cabac_tb -Wno-fatal \
  +define+H264_CABAC_FAULT_SKIP_RENORM \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
RENORM_OUT="$($BUILD_RENORM/Vh264_cabac_tb 2>&1)"
RENORM_RC=$?
set -e
printf '%s\n' "$RENORM_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_cabac_skip_renorm "$RENORM_RC" <<<"$RENORM_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$RENORM_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_INIT" \
  --top-module h264_cabac_tb -Wno-fatal \
  +define+H264_CABAC_FAULT_BAD_INIT \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
INIT_OUT="$($BUILD_INIT/Vh264_cabac_tb 2>&1)"
INIT_RC=$?
set -e
printf '%s\n' "$INIT_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_cabac_bad_init "$INIT_RC" <<<"$INIT_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$INIT_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_cabac red-checks: skipped renorm and inverted init MPS both failed"
