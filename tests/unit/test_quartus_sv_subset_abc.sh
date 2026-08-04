#!/usr/bin/env bash
# Controls for quartus-sv-subset classes A/B/C (parent fit escapes 2026-08-04).
# true rc captured directly — never grep FAIL as a test result.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="$ROOT/scripts/check_quartus_sv_subset.py"
FX="$ROOT/tests/unit/fixtures/quartus_sv_subset"
export QUARTUS_SV_SUBSET_STATIC_ONLY=1

pass=0
fail=0

run() {
  local label="$1"; shift
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "CONTROL $label true rc=$rc"
}

echo "=== NEG A: // in .qip must REJECT ==="
run neg_a python3 "$G" --static-only --no-project-scan "$FX/neg_a/bad.qip"
if [[ "$rc" -eq 1 ]] && grep -q 'Class A' <<<"$out" && grep -q 'bad.qip:2' <<<"$out"; then
  echo "NEG_A PASS"
  pass=$((pass+1))
else
  echo "NEG_A FAIL want rc=1 Class A file:line" >&2
  fail=$((fail+1))
fi

echo "=== NEG B: duplicate module across QIP files must REJECT ==="
run neg_b python3 "$G" --static-only --project-dir "$FX/neg_b"
if [[ "$rc" -eq 1 ]] && grep -q 'Class B duplicate module `dup_widget`' <<<"$out" \
   && grep -q 'a.sv:' <<<"$out" && grep -q 'b.sv:' <<<"$out"; then
  echo "NEG_B PASS"
  pass=$((pass+1))
else
  echo "NEG_B FAIL want rc=1 Class B with both declaring sites" >&2
  fail=$((fail+1))
fi

echo "=== NEG C: port defaults must REJECT (2 lines) ==="
run neg_c python3 "$G" --static-only --no-project-scan "$FX/neg_c/bad_ports.sv"
if [[ "$rc" -eq 1 ]] && grep -q 'Class C' <<<"$out"; then
  ccount=$(grep -c 'Class C' <<<"$out" || true)
  if [[ "$ccount" -ge 2 ]] && grep -q 'bit_ready' <<<"$out"; then
    echo "NEG_C PASS count=$ccount"
    pass=$((pass+1))
  else
    echo "NEG_C FAIL want >=2 Class C including bit_ready, got $ccount" >&2
    fail=$((fail+1))
  fi
else
  echo "NEG_C FAIL want rc=1 Class C" >&2
  fail=$((fail+1))
fi

echo "=== POS C: trailing // with = must PASS (no false positive) ==="
run pos_c python3 "$G" --static-only --no-project-scan "$FX/pos_c_comment/ok_ports.sv"
if [[ "$rc" -eq 0 ]] && grep -q 'STATIC_PASS' <<<"$out"; then
  if grep -q 'Class C' <<<"$out"; then
    echo "POS_C FAIL false-positive Class C on comment" >&2
    fail=$((fail+1))
  else
    echo "POS_C PASS"
    pass=$((pass+1))
  fi
else
  echo "POS_C FAIL want rc=0 STATIC_PASS" >&2
  fail=$((fail+1))
fi

echo "=== POS project: current Plex tree A/B/C clean ==="
PROJ="$ROOT/fpga/Plex_MiSTer"
run pos_proj_abc python3 "$G" --static-only --project-dir "$PROJ" \
  $("$ROOT/scripts/rtl_lint.py" --list-files 2>/dev/null | tr '\n' ' ')
if grep -q 'Class A' <<<"$out"; then
  echo "POS_ABC FAIL Class A still present on tree" >&2
  fail=$((fail+1))
elif grep -q 'Class B' <<<"$out"; then
  echo "POS_ABC FAIL Class B still present on tree" >&2
  fail=$((fail+1))
elif grep -q 'Class C' <<<"$out"; then
  echo "POS_ABC FAIL Class C still present on tree" >&2
  grep 'Class C' <<<"$out" || true
  fail=$((fail+1))
elif [[ "$rc" -ne 0 ]]; then
  echo "POS_ABC FAIL want rc=0, got $rc" >&2
  fail=$((fail+1))
else
  echo "CLASS_C_PRODUCT_OPEN=0"
  echo "POS_ABC PASS product_scan rc=0"
  pass=$((pass+1))
fi

echo "=== SUMMARY pass=$pass fail=$fail ==="
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
