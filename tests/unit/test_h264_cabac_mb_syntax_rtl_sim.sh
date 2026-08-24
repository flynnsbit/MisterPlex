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
SKIP RTL SIM: Verilator not found; h264_cabac_mb_syntax simulation was NOT run.
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

TOP="$ROOT/tests/rtl/h264_cabac_mb_syntax_tb.sv"
TB="$ROOT/tests/rtl/h264_cabac_mb_syntax_tb.cpp"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cabac.sv"
INCDIR="$ROOT/fpga/Plex_MiSTer/rtl"
BUILD="$ROOT/build/verilator/h264_cabac_mb_syntax"
BUILD_SKIP="$ROOT/build/verilator/h264_cabac_mb_syntax_force_skip"
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
if ! grep -Rq 'h264_cabac_mb_syntax u_cabac_syn' "$ROOT/fpga/Plex_MiSTer/rtl"; then
  echo "RTL SIM ERROR: product decode_core does not instantiate h264_cabac_mb_syntax u_cabac_syn" >&2
  exit 2
fi
if ! grep -q 'module h264_cabac_mb_syntax' "$RTL"; then
  echo "RTL SIM ERROR: h264_cabac.sv is missing h264_cabac_mb_syntax" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_SKIP"
echo "RTL SIM: using $VERILATOR_VERSION (h264_cabac_mb_syntax)" >&2
INCFLAGS="-std=c++17 -O2 -I$ROOT/tests/rtl"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_cabac_mb_syntax_tb -Wno-fatal \
  +incdir+"$INCDIR" \
  -CFLAGS "$INCFLAGS" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_cabac_mb_syntax_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SKIP" \
  --top-module h264_cabac_mb_syntax_tb -Wno-fatal \
  +incdir+"$INCDIR" \
  +define+H264_CABAC_SYN_FAULT_FORCE_SKIP \
  -CFLAGS "$INCFLAGS -DH264_CABAC_SYN_FAULT_FORCE_SKIP" \
  "$TOP" "$RTL" "$TB"
set +e
SKIP_OUT="$($BUILD_SKIP/Vh264_cabac_mb_syntax_tb 2>&1)"
SKIP_RC=$?
set -e
printf '%s\n' "$SKIP_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_cabac_mb_syntax_force_skip "$SKIP_RC" <<<"$SKIP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SKIP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_cabac_mb_syntax red-check: forced mb_skip_flag stayed skip"
