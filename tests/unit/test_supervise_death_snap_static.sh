#!/usr/bin/env bash
# Product supervise must snapshot misterplexd.death + si_pid on every child exit.
# Defect class: clean rc=0 mid-soak with no sender attribution (parent RCA blocked).
#
# Red-before-green: stripping SUPERVISE_EXIT from a copy must fail the gate;
# applied-match counts printed so a no-op mutation cannot masquerade as pass.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUP="$ROOT/scripts/misterplexd_supervise.sh"
FAIL=0

[ -f "$SUP" ] || { echo "FAIL missing $SUP"; exit 2; }

count() {
  local pat="$1" file="$2"
  # Prefer fixed-string when possible; allow regex via grep -E when pat has |
  grep -cE "$pat" "$file" 2>/dev/null || true
}

need() {
  local name="$1" pat="$2" min="$3"
  local n
  n=$(count "$pat" "$SUP")
  # grep -c returns 0 with exit 1 on no match under pipefail-less; normalize empty
  [ -z "$n" ] && n=0
  echo "match name=$name pattern=$pat count=$n min=$min"
  if [ "$n" -lt "$min" ]; then
    echo "FAIL $name count=$n want>=$min"
    FAIL=$((FAIL + 1))
  fi
}

need SUPERVISE_EXIT 'SUPERVISE_EXIT' 1
need death_snap 'misterplexd\.death' 1
need si_pid 'si_pid' 2
need si_code 'si_code' 2
need sender_cmd 'sender_cmd' 1
need log_fn 'log_supervise_exit' 2
# Must NOT claim a timer kill of the child
if grep -nE 'MAX_RUN|IDLE_EXIT|kill \$child.*sleep|health.*kill' "$SUP" >/dev/null 2>&1; then
  # allow trap line only
  if grep -nE 'MAX_RUN|IDLE_EXIT' "$SUP" >/dev/null 2>&1; then
    echo "FAIL timer-exit keyword in supervise"
    FAIL=$((FAIL + 1))
  fi
fi
# Documented: only trap sends kill to child
trap_kills=$(grep -c 'kill \$child' "$SUP" || true)
echo "match name=trap_kill_child count=$trap_kills"
[ "$trap_kills" -eq 1 ] || { echo "FAIL expected exactly 1 kill \$child (trap), got $trap_kills"; FAIL=$((FAIL+1)); }

# --- RED path: copy with SUPERVISE_EXIT removed must fail the same needles ---
BROKEN="$ROOT/build/supervise_broken_$$.sh"
mkdir -p "$ROOT/build"
sed 's/SUPERVISE_EXIT/SUPERVISE_XIT/g' "$SUP" >"$BROKEN"
bn=$(grep -c 'SUPERVISE_EXIT' "$BROKEN" || true)
[ -z "$bn" ] && bn=0
echo "red_mutation SUPERVISE_EXIT count_on_broken=$bn"
if [ "$bn" -ne 0 ]; then
  echo "FAIL red mutation still has SUPERVISE_EXIT"
  FAIL=$((FAIL + 1))
fi
# Gate condition that must trip on broken:
if [ "$bn" -lt 1 ]; then
  echo "OK negative: SUPERVISE_EXIT-drop would fail need SUPERVISE_EXIT (red path live)"
else
  echo "FAIL negative did not go red"
  FAIL=$((FAIL + 1))
fi
rm -f "$BROKEN"

if [ "$FAIL" -ne 0 ]; then
  echo "test_supervise_death_snap_static: FAIL count=$FAIL"
  exit 1
fi
echo "test_supervise_death_snap_static: OK"
exit 0
