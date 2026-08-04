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
  if ! grep -qE '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+VERILOG_MACRO[[:space:]]+"PRODUCT_NO_STUB' "$QSF"; then
    # Prefer anchoring near an existing product macro; fall back to append.
    if grep -q 'VERILOG_MACRO "DDR_FRAME_STORE=1"' "$QSF"; then
      sed -i 's/VERILOG_MACRO "DDR_FRAME_STORE=1"/VERILOG_MACRO "DDR_FRAME_STORE=1"\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"/' "$QSF"
    else
      printf '\nset_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"\n' >>"$QSF"
    fi
  fi
}

# Reconcile: origin landed PRODUCT_NO_STUB as product default. Baseline must
# force-clear it (and restore a non-ifdef stub path) so "no macro → stub
# REACHABLE" remains an executed control, not a hollow assumption on tip QSF.
strip_pns_qsf() {
  sed -i -E '/^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+VERILOG_MACRO[[:space:]]+"PRODUCT_NO_STUB/d' "$QSF"
}

# stream_path tip already has `ifdef PRODUCT_NO_STUB` around decode_stub. For
# baseline (no macro) that is correct — ifdef inactive → stub instantiated.
# For hollow red: PNS set but we need stub STILL in the graph → temporarily
# use a stream_path without the ifdef guard (pre-nostub shape).
make_hollow_stream_path() {
  # PNS set but stub still instantiated: keep only the `else body (decode_stub).
  if grep -q '`ifdef PRODUCT_NO_STUB' "$SP"; then
    python3 - "$SP" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
pat = re.compile(
    r"`ifdef\s+PRODUCT_NO_STUB\b.*?`else\b(.*?)^`endif\s*$",
    re.S | re.M,
)
text2, n = pat.subn(r"\1", text, count=1)
if n != 1:
    sys.stderr.write(f"hollow SP: expected 1 PRODUCT_NO_STUB ifdef/else/endif, got {n}\n")
    sys.exit(2)
open(path, "w").write(text2)
PY
  fi
}

echo "=== GREEN baseline (no PRODUCT_NO_STUB) ==="
strip_pns_qsf
# Restore tip stream_path (ifdef present but inactive without macro)
cp "$SP_BAK" "$SP"
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
cp "$SP_BAK" "$SP"
make_hollow_stream_path
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
# Tip stream_path already carries the nostub ifdef (landed with PRODUCT_NO_STUB).
# Prefer tip; fall back to historical 96163ed9 object if tip lost the guard.
cp "$SP_BAK" "$SP"
if ! grep -q '`ifdef PRODUCT_NO_STUB' "$SP"; then
  if git -C "$ROOT" cat-file -e 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv 2>/dev/null; then
    git -C "$ROOT" show 96163ed9:fpga/Plex_MiSTer/rtl/stream_path.sv >"$SP"
  else
    echo "SKIP-NOT-PASS nostub stream_path ifdef unavailable" >&2
    exit 77
  fi
fi
inject_pns
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
