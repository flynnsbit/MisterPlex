#!/usr/bin/env bash
# Prefit reachability must track PRODUCT_NO_STUB (w-nostub reclaim).
# Product QSF default is PRODUCT_NO_STUB=1 (Path A). Cases:
#   GREEN baseline: macro OFF → decode_stub REACHABLE (research/sim path)
#   RED hollow:     macro ON + stream_path still instantiates stub → teeth FAIL
#   GREEN strip:    macro ON + ifdef-stripped stream_path → decode_stub PRUNED
# Soft-skip≠PASS. true rc captured directly (never through a pipe alone).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_prefit_reachability.py"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
# Pre-PRODUCT_NO_STUB stream_path (always instantiates decode_stub)
PRE_NOSTUB_SP_REF="3d0b6aaef386ffec4c4c12b51d425896ba32145b"

echo "=== test_prefit_reachability_product_no_stub EXECUTED ==="
test -f "$GATE" && test -f "$SP" && test -f "$QSF"

SP_BAK=$(mktemp)
Q_BAK=$(mktemp)
cp "$SP" "$SP_BAK"
cp "$QSF" "$Q_BAK"
cleanup() { cp "$SP_BAK" "$SP"; cp "$Q_BAK" "$QSF"; rm -f "$SP_BAK" "$Q_BAK"; }
trap cleanup EXIT

strip_pns() {
  # Remove PRODUCT_NO_STUB macro lines from QSF (product default is ON).
  sed -i '/VERILOG_MACRO "PRODUCT_NO_STUB/d' "$QSF"
  if grep -q 'PRODUCT_NO_STUB' "$QSF"; then
    echo "FAIL could not strip PRODUCT_NO_STUB from QSF" >&2
    exit 1
  fi
}

inject_pns() {
  strip_pns
  sed -i 's/VERILOG_MACRO "DDR_FRAME_STORE=1"/VERILOG_MACRO "DDR_FRAME_STORE=1"\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"/' "$QSF"
  grep -q 'PRODUCT_NO_STUB' "$QSF" || { echo "FAIL inject PRODUCT_NO_STUB" >&2; exit 1; }
}

echo "=== GREEN baseline (no PRODUCT_NO_STUB) ==="
# Keep committed stream_path (has ifdef); with macro OFF the `else` keeps stub.
strip_pns
cp "$SP_BAK" "$SP"
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "baseline true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' || { echo "FAIL baseline decode_stub not REACHABLE" >&2; exit 1; }
echo "$out" | grep -q 'PREFIT_REACHABILITY_PRODUCT_NO_STUB=0' || { echo "FAIL baseline macro still on" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL baseline gate" >&2; exit 1; }
echo "PASS baseline"

echo "=== RED hollow: PRODUCT_NO_STUB but stub still in graph ==="
inject_pns
if ! git -C "$ROOT" cat-file -e "${PRE_NOSTUB_SP_REF}:fpga/Plex_MiSTer/rtl/stream_path.sv" 2>/dev/null; then
  echo "SKIP-NOT-PASS pre-nostub stream_path ${PRE_NOSTUB_SP_REF} unavailable" >&2
  exit 77
fi
git -C "$ROOT" show "${PRE_NOSTUB_SP_REF}:fpga/Plex_MiSTer/rtl/stream_path.sv" >"$SP"
# Positive control: hollow source must instantiate stub unconditionally
grep -q 'decode_stub' "$SP" || { echo "FAIL hollow stream_path missing decode_stub" >&2; exit 1; }
if grep -q 'PRODUCT_NO_STUB' "$SP"; then
  echo "FAIL hollow stream_path still has PRODUCT_NO_STUB ifdef" >&2
  exit 1
fi
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "hollow true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' \
  || { echo "FAIL hollow did not see REACHABLE stub tooth" >&2; exit 1; }
echo "$out" | grep -q 'PREFIT_REACHABILITY_PRODUCT_NO_STUB=1' \
  || { echo "FAIL hollow macro not seen" >&2; exit 1; }
[[ "$rc" -ne 0 ]] || { echo "FAIL hollow unexpectedly green" >&2; exit 1; }
echo "PASS hollow red-check true_rc=$rc"

echo "=== GREEN strip: PRODUCT_NO_STUB + ifdef-stripped stream_path ==="
inject_pns
cp "$SP_BAK" "$SP"
grep -q 'PRODUCT_NO_STUB' "$SP" || { echo "FAIL strip stream_path missing ifdef" >&2; exit 1; }
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "strip true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=PRUNED' || { echo "FAIL strip decode_stub not PRUNED" >&2; exit 1; }
echo "$out" | grep -q 'PREFIT_REACHABILITY_PRODUCT_NO_STUB=1' || { echo "FAIL strip macro not seen" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL strip gate" >&2; exit 1; }
echo "PASS strip green-check"
echo "PASS test_prefit_reachability_product_no_stub"
echo "true rc=0"
exit 0
