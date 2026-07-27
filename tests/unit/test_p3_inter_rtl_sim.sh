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
SKIP RTL SIM: Verilator not found; h264_inter_pred real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TB="$ROOT/tests/rtl/h264_inter_pred_tb.cpp"
TOP="$ROOT/tests/rtl/h264_inter_pred_tb_top.sv"
FIXTURE="$ROOT/tests/fixtures/p3_inter_pred/inter_mc_v1.json"
BUILD="$ROOT/build/verilator/h264_inter_pred"
BUILD_FAULT="$ROOT/build/verilator/h264_inter_pred_bad_round"
REGEN="$ROOT/build/p3_inter_mc_v1.regen.json"

for f in "$RTL" "$QIP" "$TB" "$TOP" "$FIXTURE"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_inter_pred.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list the product RTL under simulation" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_FAULT"
python3 "$ROOT/scripts/gen_p3_inter_mc_fixture.py" "$REGEN" >/dev/null
if ! cmp -s "$FIXTURE" "$REGEN"; then
  echo "RTL SIM ERROR: inter MC fixture is not byte-identical to generator" >&2
  exit 2
fi
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_inter_pred_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_inter_pred_tb" "$FIXTURE"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module h264_inter_pred_tb -GFAULT_BAD_ROUND=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
FAULT_OUT="$("$BUILD_FAULT/Vh264_inter_pred_tb" "$FIXTURE" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL h264_inter_pred RTL red-check: bad qpel/chroma rounding unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'luma qpel frac mismatch' <<<"$FAULT_OUT"; then
  echo "FAIL h264_inter_pred RTL red-check: expected luma qpel mismatch" >&2
  exit 1
fi
echo "OK h264_inter_pred RTL red-check: bad rounding fault failed golden"
