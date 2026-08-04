#!/usr/bin/env bash
# Prefit reachability must track PRODUCT_NO_STUB (w-nostub reclaim / Path A).
#
# Origin product default (PR #2): PRODUCT_NO_STUB=1 in QSF + stream_path ifdef
# strips decode_stub → PRUNED (not REACHABLE).
#
# Cases:
#   GREEN product: QSF as-shipped → decode_stub PRUNED, gate rc=0
#   GREEN baseline: strip macro from QSF only → decode_stub REACHABLE, rc=0
#   RED hollow: macro set but stream_path ifdef neutralized → stub REACHABLE
#               while teeth list it → gate must FAIL
#
# Soft-skip≠PASS. true rc captured directly (never through a pipe).
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

echo "=== GREEN product default (PRODUCT_NO_STUB shipped) ==="
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "product true rc=$rc"
echo "$out" | grep -q 'PRODUCT_NO_STUB=1\|PREFIT_REACHABILITY_PRODUCT_NO_STUB=1' \
  || { echo "FAIL product macro not seen" >&2; exit 1; }
echo "$out" | grep -q 'decode_stub STATUS=PRUNED' \
  || { echo "FAIL product decode_stub not PRUNED" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL product gate" >&2; exit 1; }
echo "PASS product default"

echo "=== GREEN baseline (no PRODUCT_NO_STUB in QSF) ==="
sed -i '/PRODUCT_NO_STUB/d' "$QSF"
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -5
echo "baseline true rc=$rc"
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' \
  || { echo "FAIL baseline decode_stub not REACHABLE" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL baseline gate" >&2; exit 1; }
echo "PASS baseline"
cp "$Q_BAK" "$QSF"

echo "=== RED hollow: PRODUCT_NO_STUB but stub still instantiated ==="
# Neutralize the product ifdef so stub remains in the graph under the macro.
# A naive gate that ignores teeth_if_macro_present would still PASS; this must FAIL.
sed -i 's/`ifdef PRODUCT_NO_STUB/`ifdef PRODUCT_NO_STUB_HOLLOW_DISABLED/' "$SP"
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "hollow true rc=$rc"
echo "$out" | grep -Eq 'decode_stub:REACHABLE_but_listed_as_teeth|decode_stub STATUS=REACHABLE' \
  || { echo "FAIL hollow did not see REACHABLE stub tooth" >&2; exit 1; }
[[ "$rc" -ne 0 ]] || { echo "FAIL hollow unexpectedly green" >&2; exit 1; }
echo "PASS hollow red-check true_rc=$rc"
cp "$SP_BAK" "$SP"
cp "$Q_BAK" "$QSF"

echo "PASS test_prefit_reachability_product_no_stub"
echo "true rc=0"
exit 0
