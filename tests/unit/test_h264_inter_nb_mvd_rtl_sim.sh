#!/usr/bin/env bash
# Real RTL sim: mvd_l0 se(v) path is covered by baseline_syntax; this gate covers
# neighbour MV context + median MVP + mvd add against reference-decoder MVs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_inter_nb_mvd real RTL simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

NB="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_nb_ctx.sv"
MVP="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_inter_nb_mvd_tb_top.sv"
TB="$ROOT/tests/rtl/h264_inter_nb_mvd_tb.cpp"
FIXTURE="$ROOT/tests/fixtures/p3_inter_pred/pframe1_mb_v1.json"
BUILD="$ROOT/build/verilator/h264_inter_nb_mvd"
BUILD_SWAP="$ROOT/build/verilator/h264_inter_nb_mvd_swap_ab"
BUILD_DROP="$ROOT/build/verilator/h264_inter_nb_mvd_drop_c"

for f in "$NB" "$MVP" "$QIP" "$TOP" "$TB" "$FIXTURE"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_inter_nb_ctx.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_inter_nb_ctx.sv" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_inter_pred.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_inter_pred.sv" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_SWAP" "$BUILD_DROP"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

# PRE-REGISTER (frame walk on pframe1_mb_v1.json):
#   expect 300/300 MBs to round-trip (279 coded + 21 skip) once nb_ctx+mvp+mvd land.
#   expect ≥145 non-zero golden MVs to match (fixture nonzero count).
#   Falsifiers: FAULT_SWAP_AB and FAULT_DROP_C_FALLBACK must RED.

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_inter_nb_mvd_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$NB" "$MVP" "$TB"
"$BUILD/Vh264_inter_nb_mvd_tb" "$FIXTURE"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SWAP" \
  --top-module h264_inter_nb_mvd_tb -GFAULT_SWAP_AB=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$NB" "$MVP" "$TB"
set +e
SWAP_OUT="$("$BUILD_SWAP/Vh264_inter_nb_mvd_tb" "$FIXTURE" 2>&1)"
SWAP_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_inter_nb_ctx_swap_ab "$SWAP_RC" <<<"$SWAP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_inter_nb_mvd red-check: swap A/B fault failed golden"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP" \
  --top-module h264_inter_nb_mvd_tb -GFAULT_DROP_C_FALLBACK=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$NB" "$MVP" "$TB"
set +e
DROP_OUT="$("$BUILD_DROP/Vh264_inter_nb_mvd_tb" "$FIXTURE" 2>&1)"
DROP_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_inter_nb_ctx_drop_c_fallback "$DROP_RC" <<<"$DROP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_inter_nb_mvd red-check: drop C→D fallback fault failed golden"
