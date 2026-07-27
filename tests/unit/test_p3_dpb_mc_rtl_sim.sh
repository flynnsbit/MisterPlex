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
SKIP RTL SIM: Verilator not found; h264_dpb_mc real RTL simulation was NOT run.
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TB="$ROOT/tests/rtl/h264_dpb_mc_tb.cpp"
TOP="$ROOT/tests/rtl/h264_dpb_mc_tb_top.sv"
FIXTURE="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264"
BUILD="$ROOT/build/verilator/h264_dpb_mc"
BUILD_CLAMP_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_clamp"
BUILD_MC_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_mc_round"
BUILD_REF_FAULT="$ROOT/build/verilator/h264_dpb_mc_early_ref"
BUILD_PART_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_part_mask"

for f in "$RTL" "$QIP" "$TB" "$TOP" "$FIXTURE"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_dpb.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list the DPB product RTL under simulation" >&2
  exit 2
fi
NAL_COUNT="$(python3 - "$FIXTURE" <<'PY'
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
n = 0
for i in range(2, len(b)):
    if b[i-2:i+1] == b"\x00\x00\x01" or (i >= 3 and b[i-3:i+1] == b"\x00\x00\x00\x01"):
        n += 1
print(n)
PY
)"
if [[ "$NAL_COUNT" -lt 2 ]]; then
  echo "RTL SIM ERROR: DPB/MC bench fixture must contain >=2 NAL units, got $NAL_COUNT" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_CLAMP_FAULT" "$BUILD_MC_FAULT" "$BUILD_REF_FAULT" "$BUILD_PART_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_dpb_mc_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
"$BUILD/Vh264_dpb_mc_tb" "$FIXTURE"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_CLAMP_FAULT" \
  --top-module h264_dpb_mc_tb -GFAULT_BAD_CLAMP=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
CLAMP_OUT="$("$BUILD_CLAMP_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" 2>&1)"
CLAMP_RC=$?
set -e
printf '%s\n' "$CLAMP_OUT"
if [[ "$CLAMP_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: bad edge clamp unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'luma window clamp mismatch' <<<"$CLAMP_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected luma clamp mismatch" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: bad edge clamp fault failed golden"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_MC_FAULT" \
  --top-module h264_dpb_mc_tb -GFAULT_BAD_MC_ROUND=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
MC_OUT="$("$BUILD_MC_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" 2>&1)"
MC_RC=$?
set -e
printf '%s\n' "$MC_OUT"
if [[ "$MC_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: bad MC arithmetic unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'MC luma prediction mismatch' <<<"$MC_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected MC luma mismatch" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: bad MC arithmetic fault failed golden"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_REF_FAULT" \
  --top-module h264_dpb_mc_tb -GFAULT_EARLY_REF=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
REF_OUT="$("$BUILD_REF_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" 2>&1)"
REF_RC=$?
set -e
printf '%s\n' "$REF_OUT"
if [[ "$REF_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: early reference publication unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'early reference publication' <<<"$REF_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected early reference publication failure" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: early reference publication fault failed golden"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_PART_FAULT" \
  --top-module h264_dpb_mc_tb -GFAULT_BAD_PART_MASK=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
set +e
PART_OUT="$("$BUILD_PART_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" 2>&1)"
PART_RC=$?
set -e
printf '%s\n' "$PART_OUT"
if [[ "$PART_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: bad partition mask unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'part luma prediction/mask mismatch' <<<"$PART_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected partition mask mismatch" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: bad partition mask fault failed golden"
