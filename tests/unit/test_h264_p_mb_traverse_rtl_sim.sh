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
SKIP RTL SIM: Verilator not found; h264_p_mb_traverse real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_p_mb_traverse.sv"
CAVLC="$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv"
MODES="$ROOT/fpga/Plex_MiSTer/rtl/h264_p_slice_modes.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_p_mb_traverse_tb_top.sv"
TB="$ROOT/tests/rtl/h264_p_mb_traverse_tb.cpp"
BUILD="$ROOT/build/verilator/h264_p_mb_traverse"
BUILD_BAD="$ROOT/build/verilator/h264_p_mb_traverse_bad_skip"
BUILD_DROP="$ROOT/build/verilator/h264_p_mb_traverse_drop_last"
BUILD_ZMVD="$ROOT/build/verilator/h264_p_mb_traverse_zero_mvd"

for f in "$RTL" "$CAVLC" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_p_mb_traverse.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_p_mb_traverse.sv product RTL" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_BAD" "$BUILD_DROP" "$BUILD_ZMVD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

# Green path
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_p_mb_traverse_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$CAVLC" $([ -f "$MODES" ] && echo "$MODES") "$TB"
"$BUILD/Vh264_p_mb_traverse_tb_top" green

# Mutation: bad skip_run
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_BAD" \
  --top-module h264_p_mb_traverse_tb_top -GFAULT_BAD_SKIP_RUN=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$CAVLC" $([ -f "$MODES" ] && echo "$MODES") "$TB"
set +e
BAD_OUT="$("$BUILD_BAD/Vh264_p_mb_traverse_tb_top" fault_bad_skip 2>&1)"
BAD_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_p_mb_traverse_bad_skip "$BAD_RC" <<<"$BAD_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$BAD_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"

# Mutation: drop last MB of each row
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP" \
  --top-module h264_p_mb_traverse_tb_top -GFAULT_DROP_LAST_ROW_MB=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$CAVLC" $([ -f "$MODES" ] && echo "$MODES") "$TB"
set +e
DROP_OUT="$("$BUILD_DROP/Vh264_p_mb_traverse_tb_top" fault_drop_last 2>&1)"
DROP_RC=$?
set -e
if ! RED_CHECK2="$(python3 "$ROOT/tests/unit/expected_red.py" h264_p_mb_traverse_drop_last_row "$DROP_RC" <<<"$DROP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK2" "$DROP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK2"

# Mutation: force exported mvd to zero (proves mvd path is live)
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_ZMVD" \
  --top-module h264_p_mb_traverse_tb_top -GFAULT_FORCE_ZERO_MVD=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$CAVLC" $([ -f "$MODES" ] && echo "$MODES") "$TB"
set +e
ZMVD_OUT="$("$BUILD_ZMVD/Vh264_p_mb_traverse_tb_top" fault_zero_mvd 2>&1)"
ZMVD_RC=$?
set -e
if ! RED_CHECK3="$(python3 "$ROOT/tests/unit/expected_red.py" h264_p_mb_traverse_zero_mvd "$ZMVD_RC" <<<"$ZMVD_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK3" "$ZMVD_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK3"

echo "OK h264_p_mb_traverse: walk + mvd export + three mutation red-checks"
