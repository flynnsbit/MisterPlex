#!/usr/bin/env bash
# Prefit reachability must track PRODUCT_NO_STUB (w-nostub reclaim).
#
# GREEN baseline: QSF without PRODUCT_NO_STUB + tip stream_path (stub in `else`)
#   → decode_stub REACHABLE, gate rc=0
# RED hollow: PRODUCT_NO_STUB set + pre-nostub stream_path (always instances stub)
#   → decode_stub REACHABLE_but_listed_as_teeth, gate rc!=0
# GREEN strip: PRODUCT_NO_STUB + tip/ifdef stream_path
#   → decode_stub PRUNED, gate rc=0
#
# Soft-skip≠PASS. true rc direct. Scratch under .agent-work (not /tmp).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_prefit_reachability.py"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
WORK="$ROOT/.agent-work/prefit-pns-gate"
mkdir -p "$WORK"

echo "=== test_prefit_reachability_product_no_stub EXECUTED ==="
test -f "$GATE" && test -f "$SP" && test -f "$QSF"

cp "$SP" "$WORK/stream_path.sv.bak"
cp "$QSF" "$WORK/Plex.qsf.bak"
cleanup() {
  cp "$WORK/stream_path.sv.bak" "$SP"
  cp "$WORK/Plex.qsf.bak" "$QSF"
}
trap cleanup EXIT

strip_pns_qsf() {
  grep -v 'PRODUCT_NO_STUB' "$WORK/Plex.qsf.bak" >"$QSF"
}

inject_pns_qsf() {
  if ! grep -q 'PRODUCT_NO_STUB' "$QSF"; then
    sed -i 's/VERILOG_MACRO "DDR_FRAME_STORE=1"/VERILOG_MACRO "DDR_FRAME_STORE=1"\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"/' "$QSF"
  fi
}

echo "=== GREEN baseline (no PRODUCT_NO_STUB) ==="
cp "$WORK/stream_path.sv.bak" "$SP"
strip_pns_qsf
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "baseline true rc=$rc"
echo "$out" | grep -q 'PREFIT_REACHABILITY_PRODUCT_NO_STUB=0' \
  || { echo "FAIL baseline still sees PRODUCT_NO_STUB" >&2; exit 1; }
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' \
  || { echo "FAIL baseline decode_stub not REACHABLE" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL baseline gate rc=$rc" >&2; exit 1; }
echo "PASS baseline"

echo "=== RED hollow: PRODUCT_NO_STUB but stub always-instanced (pre-nostub SP) ==="
PRE_NOSTUB_SP_OBJ='c0c686a4^:fpga/Plex_MiSTer/rtl/stream_path.sv'
if ! git -C "$ROOT" cat-file -e 'c0c686a4^:fpga/Plex_MiSTer/rtl/stream_path.sv' 2>/dev/null; then
  echo "FAIL: missing git object $PRE_NOSTUB_SP_OBJ (needed for hollow positive control)" >&2
  exit 1
fi
git -C "$ROOT" show "$PRE_NOSTUB_SP_OBJ" >"$SP"
if grep -q 'PRODUCT_NO_STUB' "$SP"; then
  echo "FAIL: pre-nostub stream_path still mentions PRODUCT_NO_STUB" >&2
  exit 1
fi
grep -q 'decode_stub' "$SP" || { echo "FAIL: pre-nostub stream_path missing decode_stub" >&2; exit 1; }
cp "$WORK/Plex.qsf.bak" "$QSF"
inject_pns_qsf
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "hollow true rc=$rc"
echo "$out" | grep -q 'PREFIT_REACHABILITY_PRODUCT_NO_STUB=1' \
  || { echo "FAIL hollow missing PRODUCT_NO_STUB=1" >&2; exit 1; }
echo "$out" | grep -qE 'decode_stub:REACHABLE_but_listed_as_teeth|decode_stub STATUS=REACHABLE' \
  || { echo "FAIL hollow did not see REACHABLE stub tooth" >&2; exit 1; }
[[ "$rc" -ne 0 ]] || { echo "FAIL hollow unexpectedly green rc=0" >&2; exit 1; }
echo "PASS hollow red-check true_rc=$rc"

echo "=== GREEN strip: PRODUCT_NO_STUB + ifdef-stripped stream_path ==="
cp "$WORK/stream_path.sv.bak" "$SP"
if ! grep -q 'PRODUCT_NO_STUB' "$SP"; then
  if git -C "$ROOT" cat-file -e 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv 2>/dev/null; then
    git -C "$ROOT" show 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv >"$SP"
  else
    echo "FAIL: tip stream_path lacks PRODUCT_NO_STUB and 96163ed9 unavailable" >&2
    exit 1
  fi
fi
cp "$WORK/Plex.qsf.bak" "$QSF"
inject_pns_qsf
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "strip true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=PRUNED' \
  || { echo "FAIL strip decode_stub not PRUNED" >&2; exit 1; }
echo "$out" | grep -q 'PRODUCT_NO_STUB=1' \
  || { echo "FAIL strip macro not seen" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL strip gate rc=$rc" >&2; exit 1; }
echo "PASS strip green-check"
echo "PASS test_prefit_reachability_product_no_stub"
echo "true rc=0"
exit 0
