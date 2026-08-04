#!/usr/bin/env bash
# Prefit reachability must track PRODUCT_NO_STUB (w-nostub reclaim).
#
# Product default (post PR #2): QSF has PRODUCT_NO_STUB=1 and stream_path
# ifdef-strips decode_stub → stub is a TEETH (must be non-reachable).
#
# Twins:
#   A GREEN product: committed tree → decode_stub PRUNED, gate rc=0
#   B RED hollow:    PRODUCT_NO_STUB=1 but stub still instantiated → teeth FAIL
#   C GREEN legacy:  no macro + unconditional stub → decode_stub REACHABLE, rc=0
#
# Soft-skip≠PASS. Never /tmp. true rc direct.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_prefit_reachability.py"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
WORKDIR="${ROOT}/Memory/lab/fitgate-pns-twin"
mkdir -p "$WORKDIR"
echo "=== test_prefit_reachability_product_no_stub EXECUTED ==="
test -f "$GATE" && test -f "$SP" && test -f "$QSF"

cp "$SP" "$WORKDIR/stream_path.sv.bak"
cp "$QSF" "$WORKDIR/Plex.qsf.bak"
cleanup() {
  cp "$WORKDIR/stream_path.sv.bak" "$SP"
  cp "$WORKDIR/Plex.qsf.bak" "$QSF"
}
trap cleanup EXIT

# Pre-nostub stream_path (unconditional decode_stub instance) for hollow/legacy.
LEGACY_SP_REF="3d0b6aae:fpga/Plex_MiSTer/rtl/stream_path.sv"
if ! git -C "$ROOT" cat-file -e "$LEGACY_SP_REF" 2>/dev/null; then
  echo "FAIL need git object $LEGACY_SP_REF for hollow/legacy twins" >&2
  exit 2
fi
git -C "$ROOT" show "$LEGACY_SP_REF" >"$WORKDIR/stream_path_legacy.sv"

strip_pns_qsf() {
  # Drop active PRODUCT_NO_STUB macro lines (keep comments).
  sed -i '/^set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=/d' "$QSF"
}

ensure_pns_qsf() {
  if ! grep -qE '^set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"' "$QSF"; then
    sed -i 's/VERILOG_MACRO "DDR_FRAME_STORE=1"/VERILOG_MACRO "DDR_FRAME_STORE=1"\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"/' "$QSF"
  fi
}

echo "=== A GREEN product baseline (PRODUCT_NO_STUB=1, stub stripped) ==="
# Restore committed product files first
cp "$WORKDIR/stream_path.sv.bak" "$SP"
cp "$WORKDIR/Plex.qsf.bak" "$QSF"
ensure_pns_qsf
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "product true rc=$rc"
echo "$out" | grep -q 'PRODUCT_NO_STUB=1' || { echo "FAIL product macro not seen" >&2; exit 1; }
echo "$out" | grep -q 'decode_stub STATUS=PRUNED' || { echo "FAIL product decode_stub not PRUNED" >&2; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL product gate" >&2; exit 1; }
echo "PASS product baseline"
product_rc=0

echo "=== B RED hollow: PRODUCT_NO_STUB=1 but stub still instantiated ==="
ensure_pns_qsf
cp "$WORKDIR/stream_path_legacy.sv" "$SP"
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
hollow_rc=$?
set -e
printf '%s\n' "$out" | tail -10
echo "hollow true rc=$hollow_rc"
echo "$out" | grep -qE 'decode_stub:REACHABLE_but_listed_as_teeth|decode_stub STATUS=REACHABLE' \
  || { echo "FAIL hollow did not see REACHABLE stub tooth" >&2; exit 1; }
[[ "$hollow_rc" -ne 0 ]] || { echo "FAIL hollow unexpectedly green" >&2; exit 1; }
echo "PASS hollow red-check true_rc=$hollow_rc"

echo "=== C GREEN legacy: no PRODUCT_NO_STUB + unconditional stub ==="
strip_pns_qsf
cp "$WORKDIR/stream_path_legacy.sv" "$SP"
set +e
out=$(python3 "$GATE" --root "$ROOT" 2>&1)
legacy_rc=$?
set -e
printf '%s\n' "$out" | tail -8
echo "legacy true rc=$legacy_rc"
echo "$out" | grep -q 'decode_stub STATUS=REACHABLE' || { echo "FAIL legacy decode_stub not REACHABLE" >&2; exit 1; }
if echo "$out" | grep -q 'PRODUCT_NO_STUB=1'; then
  echo "FAIL legacy still sees PRODUCT_NO_STUB=1" >&2
  exit 1
fi
[[ "$legacy_rc" -eq 0 ]] || { echo "FAIL legacy gate" >&2; exit 1; }
echo "PASS legacy green-check"

echo "PASS test_prefit_reachability_product_no_stub"
echo "EXECUTED product_rc=$product_rc hollow_rc=$hollow_rc legacy_rc=$legacy_rc"
echo "true rc=0"
exit 0
