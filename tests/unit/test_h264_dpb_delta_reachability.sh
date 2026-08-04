#!/usr/bin/env bash
# DPB DELTA reachability: LIVE helpers already in graph; DDR path DEAD until wired.
# Uses tools/rtl_reachability.py (positive-control BFS from sys_top). Soft-skip ≠ pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/rtl_reachability.py"
RTL="$ROOT/fpga/Plex_MiSTer"
OUT="$ROOT/.agent-work/h264_dpb_delta_reachability.txt"
mkdir -p "$ROOT/.agent-work"

echo "DPB_DELTA_REACH_EXECUTED"

if [[ ! -f "$TOOL" ]]; then
  echo "FAIL missing $TOOL (required; not a soft-skip)"
  exit 2
fi

set +e
python3 "$TOOL" "$RTL" sys_top >"$OUT"
tool_rc=$?
set -e
cat "$OUT"
echo "true tool_rc=$tool_rc"
if [[ "$tool_rc" -ne 0 ]]; then
  echo "FAIL rtl_reachability rc=$tool_rc"
  exit "$tool_rc"
fi

# Positive controls must stay LIVE (helpers already synthesise via decode_stub path).
for m in h264_dpb_one_ref h264_dpb_i420_addr h264_dpb_mb_write_addr; do
  if ! grep -E "^[[:space:]]*LIVE ${m}([[:space:]]|$)" "$OUT" >/dev/null; then
    echo "FAIL expected LIVE $m"
    exit 1
  fi
  echo "OK LIVE $m"
done

# DDR DELTA modules must remain DEAD until fabric decode wires ENABLE_DPB_DDR.
for m in h264_dpb_ddr_backend h264_dpb_nb_cache h264_dpb_area_budget; do
  if ! grep -E "^[[:space:]]*DEAD ${m}([[:space:]]|$)" "$OUT" >/dev/null; then
    echo "FAIL expected DEAD $m (unwired DELTA must not count as paid area)"
    exit 1
  fi
  echo "OK DEAD $m (delta unwired)"
done

echo "DPB_DELTA_REACH_PASS"
echo "NOTE: tool does not eval PRODUCT_NO_STUB; post-fit hierarchy remains authority."
exit 0
