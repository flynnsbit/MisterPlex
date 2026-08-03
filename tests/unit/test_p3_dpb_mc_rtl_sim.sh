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
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
REF_COMMIT_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ref_commit.sv"
DEBLOCK_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
DEBLOCK_MB_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock_mb.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TB="$ROOT/tests/rtl/h264_dpb_mc_tb.cpp"
TOP="$ROOT/tests/rtl/h264_dpb_mc_tb_top.sv"
FIXTURE="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264"
BUILD="$ROOT/build/verilator/h264_dpb_mc"
BUILD_SEAM="$ROOT/build/verilator/h264_dpb_mc_deblock_seam"
BUILD_SEAM_MB_FAULT="$ROOT/build/verilator/h264_dpb_mc_deblock_seam_mb_fault"
BUILD_SEAM_REF_FAULT="$ROOT/build/verilator/h264_dpb_mc_deblock_seam_ref_fault"
BUILD_CLAMP_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_clamp"
BUILD_MC_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_mc_round"
BUILD_REF_FAULT="$ROOT/build/verilator/h264_dpb_mc_early_ref"
BUILD_PART_FAULT="$ROOT/build/verilator/h264_dpb_mc_bad_part_mask"
BUILD_GENUINE="$ROOT/build/verilator/h264_dpb_mc_genuine_ref"
BUILD_SKIP_DBF="$ROOT/build/verilator/h264_dpb_mc_skip_deblock"
BUILD_EARLY_PROMOTE="$ROOT/build/verilator/h264_dpb_mc_early_promote"
BUILD_NO_IDR="$ROOT/build/verilator/h264_dpb_mc_no_idr_invalidate"

COMMON_SV=("$TOP" "$RTL" "$REF_COMMIT_RTL" "$DEBLOCK_RTL" "$DEBLOCK_MB_RTL" "$TB")

for f in "$RTL" "$REF_COMMIT_RTL" "$DEBLOCK_RTL" "$DEBLOCK_MB_RTL" "$QIP" "$TB" "$TOP" "$FIXTURE"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_dpb.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list the DPB product RTL under simulation" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_deblock.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list the deblock product RTL under seam simulation" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_deblock_mb.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_deblock_mb.sv" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_dpb_ref_commit.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_dpb_ref_commit.sv" >&2
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

mkdir -p "$BUILD" "$BUILD_SEAM" "$BUILD_SEAM_MB_FAULT" "$BUILD_SEAM_REF_FAULT" \
  "$BUILD_CLAMP_FAULT" "$BUILD_MC_FAULT" "$BUILD_REF_FAULT" "$BUILD_PART_FAULT" \
  "$BUILD_GENUINE" "$BUILD_SKIP_DBF" "$BUILD_EARLY_PROMOTE" "$BUILD_NO_IDR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_dpb_mc_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
"$BUILD/Vh264_dpb_mc_tb" "$FIXTURE"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SEAM" \
  --top-module h264_dpb_mc_tb -GUSE_DEBLOCK_WB_CTRL=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
"$BUILD_SEAM/Vh264_dpb_mc_tb" "$FIXTURE" --deblock-dpb-seam

# ── Genuine decoded/deblocked reference commit path ──────────────────────
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_GENUINE" \
  --top-module h264_dpb_mc_tb -GUSE_REF_COMMIT=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
"$BUILD_GENUINE/Vh264_dpb_mc_tb" "$FIXTURE" --genuine-ref-commit

# Mutation twin: skip deblock before storage (must RED)
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SKIP_DBF" \
  --top-module h264_dpb_mc_tb -GUSE_REF_COMMIT=1 -Wno-fatal +define+H264_DPB_FAULT_SKIP_DEBLOCK \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
set +e
SKIP_OUT="$("$BUILD_SKIP_DBF/Vh264_dpb_mc_tb" "$FIXTURE" --genuine-ref-commit 2>&1)"
SKIP_RC=$?
set -e
printf '%s\n' "$SKIP_OUT"
if [[ "$SKIP_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: skip-deblock-before-storage unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'stored PRE/unfiltered samples\|edge_px_changed=' <<<"$SKIP_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected skip-deblock PRE/unfiltered diagnostic" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: skip-deblock-before-storage fault failed genuine path"

# Mutation twin: promote one frame early (must RED)
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_EARLY_PROMOTE" \
  --top-module h264_dpb_mc_tb -GUSE_REF_COMMIT=1 -Wno-fatal +define+H264_DPB_FAULT_EARLY_PROMOTE \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
set +e
EARLY_OUT="$("$BUILD_EARLY_PROMOTE/Vh264_dpb_mc_tb" "$FIXTURE" --genuine-ref-commit 2>&1)"
EARLY_RC=$?
set -e
printf '%s\n' "$EARLY_OUT"
if [[ "$EARLY_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: early frame promote unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'promoted before frame boundary\|ref_ready before frame_boundary' <<<"$EARLY_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected early promote diagnostic" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: early frame promote fault failed genuine path"

# Mutation twin: fail to invalidate on IDR (must RED)
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_NO_IDR" \
  --top-module h264_dpb_mc_tb -GUSE_REF_COMMIT=1 -Wno-fatal +define+H264_DPB_FAULT_NO_IDR_INVALIDATE \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
set +e
IDR_OUT="$("$BUILD_NO_IDR/Vh264_dpb_mc_tb" "$FIXTURE" --genuine-ref-commit 2>&1)"
IDR_RC=$?
set -e
printf '%s\n' "$IDR_OUT"
if [[ "$IDR_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: no-IDR-invalidate unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'IDR did not invalidate' <<<"$IDR_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected IDR invalidate diagnostic" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: no-IDR-invalidate fault failed genuine path"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SEAM_MB_FAULT" \
  --top-module h264_dpb_mc_tb -GUSE_DEBLOCK_WB_CTRL=1 -Wno-fatal +define+H264_DEBLOCK_FAULT_MB_COMMIT_EARLY \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
set +e
SEAM_MB_OUT="$("$BUILD_SEAM_MB_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" --deblock-dpb-seam 2>&1)"
SEAM_MB_RC=$?
set -e
printf '%s\n' "$SEAM_MB_OUT"
if [[ "$SEAM_MB_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: deblock early MB commit unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'MB commit before all filtered samples' <<<"$SEAM_MB_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected deblock early MB commit diagnostic" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: deblock early MB commit fault failed seam"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SEAM_REF_FAULT" \
  --top-module h264_dpb_mc_tb -GUSE_DEBLOCK_WB_CTRL=1 -Wno-fatal +define+H264_DEBLOCK_FAULT_REF_READY_EARLY \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
set +e
SEAM_REF_OUT="$("$BUILD_SEAM_REF_FAULT/Vh264_dpb_mc_tb" "$FIXTURE" --deblock-dpb-seam 2>&1)"
SEAM_REF_RC=$?
set -e
printf '%s\n' "$SEAM_REF_OUT"
if [[ "$SEAM_REF_RC" -eq 0 ]]; then
  echo "FAIL h264_dpb_mc RTL red-check: deblock early frame_done unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'terminal commit/ref_ready order' <<<"$SEAM_REF_OUT"; then
  echo "FAIL h264_dpb_mc RTL red-check: expected deblock early frame_done diagnostic" >&2
  exit 1
fi
echo "OK h264_dpb_mc RTL red-check: deblock early frame_done fault failed seam"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_CLAMP_FAULT" \
  --top-module h264_dpb_mc_tb -GFAULT_BAD_CLAMP=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "${COMMON_SV[@]}"
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
  "${COMMON_SV[@]}"
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
  "${COMMON_SV[@]}"
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
  "${COMMON_SV[@]}"
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
