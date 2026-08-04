#!/usr/bin/env bash
# DPB DELTA reachability with body-scoped tool (rd-duck NACK of file-wide edges).
# Requires controls=PASS in code (not docstring). Soft-skip ≠ pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/rtl_reachability.py"
RTL="$ROOT/fpga/Plex_MiSTer"
OUT="$ROOT/.agent-work/h264_dpb_delta_reachability.txt"
mkdir -p "$ROOT/.agent-work"
cd "$ROOT"

echo "DPB_DELTA_REACH_EXECUTED"

if [[ ! -f "$TOOL" ]]; then
  echo "FAIL missing $TOOL (required; not a soft-skip)"
  exit 2
fi

# NEG twin: file-wide edge extraction must be detectable as the old bug.
set +e
python3 - "$TOOL" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("rr", sys.argv[1])
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
root = Path("fpga/Plex_MiSTer").resolve()
decl_file, edges_ok, _inq, bodies = rr.build_graph(root)
known = set(decl_file)
text_of = {}
for f in set(decl_file.values()):
    text_of[f] = rr.strip_comments(f.read_text(errors="ignore"))
broken = {}
for name, f in decl_file.items():
    broken[name] = rr.instantiations(text_of[f], known)
leaf = "h264_dpb_i420_addr"
if leaf not in broken or len(broken[leaf]) == 0:
    print("NEG_TWIN_INCONCLUSIVE: leaf had 0 file-wide kids (fixture changed?)")
    sys.exit(2)
if edges_ok.get(leaf):
    print(f"FAIL body-scoped leaf still has kids: {edges_ok[leaf]}")
    sys.exit(1)
print(f"OK NEG twin: file-wide would assign {sorted(broken[leaf])} to {leaf}; body-scoped kids=0")
sys.exit(0)
PY
neg_rc=$?
set -e
echo "true neg_twin_rc=$neg_rc"
if [[ "$neg_rc" -ne 0 ]]; then
  echo "FAIL file-wide NEG twin rc=$neg_rc"
  exit "$neg_rc"
fi

set +e
python3 "$TOOL" "$RTL" sys_top >"$OUT"
tool_rc=$?
set -e
cat "$OUT"
echo "true tool_rc=$tool_rc"
if [[ "$tool_rc" -ne 0 ]]; then
  echo "FAIL rtl_reachability rc=$tool_rc (controls must PASS)"
  exit "$tool_rc"
fi

grep -q 'controls=PASS' "$OUT" || { echo "FAIL missing controls=PASS line"; exit 1; }
echo "OK controls=PASS"
grep -q 'NOT claimed: modules present in any deployed/shipping RBF' "$OUT" || {
  echo "FAIL missing NON-CLAIM shipping RBF"
  exit 1
}
echo "OK non-claim shipping RBF"
grep -q 'NOT claimed: area already paid' "$OUT" || {
  echo "FAIL missing NON-CLAIM area paid"
  exit 1
}
echo "OK non-claim area paid"

for m in h264_dpb_one_ref h264_dpb_i420_addr h264_dpb_mb_write_addr; do
  if ! grep -E "^[[:space:]]*LIVE ${m}([[:space:]]|$)" "$OUT" >/dev/null; then
    echo "FAIL expected source-graph LIVE $m"
    exit 1
  fi
  echo "OK source-graph LIVE $m"
done

for m in h264_dpb_ddr_backend h264_dpb_nb_cache h264_dpb_area_budget; do
  if ! grep -E "^[[:space:]]*DEAD ${m}([[:space:]]|$)" "$OUT" >/dev/null; then
    echo "FAIL expected DEAD $m (unwired DELTA must not count as paid area)"
    exit 1
  fi
  echo "OK DEAD $m (delta unwired; not paid area)"
done

echo "DPB_DELTA_REACH_PASS"
echo "NOTE: source-graph LIVE != shipping RBF; PRODUCT_NO_STUB not evaluated."
exit 0
