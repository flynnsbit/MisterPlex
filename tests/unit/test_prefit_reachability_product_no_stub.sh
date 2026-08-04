#!/usr/bin/env bash
# Prefit reachability must track PRODUCT_NO_STUB (w-nostub reclaim).
# GREEN main: no macro → decode_stub REACHABLE required.
# RED hollow: macro set but stub still instantiated → teeth FAIL.
# GREEN strip: macro + nostub stream_path ifdef → decode_stub PRUNED tooth OK.
# Soft-skip≠PASS. true rc direct.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_prefit_reachability.py"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
echo "=== test_prefit_reachability_product_no_stub EXECUTED ==="
test -f "$GATE" && test -f "$SP" && test -f "$QSF"

SP_BAK=$(mktemp)
Q_BAK=$(mktemp)
cp "$SP" "$SP_BAK"
cp "$QSF" "$Q_BAK"
cleanup() { cp "$SP_BAK" "$SP"; cp "$Q_BAK" "$QSF"; rm -f "$SP_BAK" "$Q_BAK"; }
trap cleanup EXIT

inject_pns() {
  if ! grep -q 'PRODUCT_NO_STUB' "$QSF"; then
    sed -i 's/VERILOG_MACRO "DDR_FRAME_STORE=1"/VERILOG_MACRO "DDR_FRAME_STORE=1"\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"/' "$QSF"
  fi
}

echo "=== GREEN baseline (no PRODUCT_NO_STUB) ==="
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -5
echo "baseline true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' || { echo "FAIL baseline decode_stub not REACHABLE" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL baseline gate" >&2; exit 1; }
echo "PASS baseline"

echo "=== RED hollow: PRODUCT_NO_STUB but stub still in graph ==="
inject_pns
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "hollow true rc=$rc"
echo "$out" | grep -q 'decode_stub:REACHABLE_but_listed_as_teeth\|decode_stub STATUS=REACHABLE' \
  || { echo "FAIL hollow did not see REACHABLE stub tooth" >&2; exit 1; }
[[ "$rc" -ne 0 ]] || { echo "FAIL hollow unexpectedly green" >&2; exit 1; }
echo "PASS hollow red-check true_rc=$rc"

echo "=== GREEN strip: PRODUCT_NO_STUB + ifdef-stripped stream_path ==="
# Minimal synthetic stream_path fragment is insufficient for full graph; use
# committed nostub tip if available, else embed controlled ifdef wrapper test via
# git show when object exists.
if git -C "$ROOT" cat-file -e 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv 2>/dev/null; then
  git -C "$ROOT" show 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv >"$SP"
else
  echo "SKIP-NOT-PASS nostub stream_path object 96163ed9 unavailable" >&2
  exit 77
fi
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "strip true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=PRUNED' || { echo "FAIL strip decode_stub not PRUNED" >&2; exit 1; }
echo "$out" | grep -q 'PRODUCT_NO_STUB=1' || { echo "FAIL strip macro not seen" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL strip gate" >&2; exit 1; }
echo "PASS strip green-check"
echo "PASS test_prefit_reachability_product_no_stub"
echo "true rc=0"
exit 0
