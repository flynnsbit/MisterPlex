#!/usr/bin/env bash
# Red-before-green for tools/soak_ledger_report.py (multi-life soak totals).
# Defect class: mid-soak rc=0 respawn zeros drops=; single-life claim is false.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/soak_ledger_report.py"
DIR="$ROOT/build/soak_ledger_report_$$"
mkdir -p "$DIR"
FAIL=0

run() {
  local name="$1" want="$2"
  shift 2
  python3 "$TOOL" "$@" >"$DIR/$name.out" 2>"$DIR/$name.err"
  local st=$?
  echo "$name true rc=$st want=$want"
  if [ "$st" -ne "$want" ]; then
    echo "FAIL $name"
    cat "$DIR/$name.out" "$DIR/$name.err" || true
    FAIL=$((FAIL + 1))
  fi
}

# --- Positive multi-life: two process lives, session_end sums ---
cat >"$DIR/multi.ledger" <<'L'
ts=2026-01-01T00:00:00Z event=process_start pid=1 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:05:00Z event=session_end pid=1 session=1 frames=100 presents=98 drops=2 publish_misses=0 residual=0 reason=eof tag=measured
ts=2026-01-01T00:05:01Z event=process_exit pid=1 code=0 why=site=main.cpp:main_loop_g_stop sig=15 si_pid=99
ts=2026-01-01T00:05:03Z event=process_start pid=2 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:10:00Z event=session_end pid=2 session=1 frames=50 presents=40 drops=5 publish_misses=5 residual=5 reason=stop tag=measured
L
run multi 0 --ledger "$DIR/multi.ledger"
if ! grep -q 'claim=MULTI_LIFE' "$DIR/multi.out"; then
  echo "FAIL multi missing MULTI_LIFE claim"; FAIL=$((FAIL+1))
fi
if ! grep -q 'REFUSE_SINGLE_LIFE_CLEAN' "$DIR/multi.out"; then
  echo "FAIL multi must refuse single-life clean claim"; FAIL=$((FAIL+1))
fi
if ! grep -q 'sum_drops=7' "$DIR/multi.out"; then
  echo "FAIL multi sum_drops want 7"; cat "$DIR/multi.out"; FAIL=$((FAIL+1))
fi
if ! grep -q 'restarts_spanned=1' "$DIR/multi.out"; then
  echo "FAIL multi restarts_spanned want 1"; cat "$DIR/multi.out"; FAIL=$((FAIL+1))
fi
if ! grep -q 'sum_frames=150' "$DIR/multi.out"; then
  echo "FAIL multi sum_frames want 150"; FAIL=$((FAIL+1))
fi

# --- Positive single-life ---
cat >"$DIR/single.ledger" <<'L'
ts=2026-01-01T00:00:00Z event=process_start pid=9 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:10:00Z event=session_end pid=9 session=1 frames=500 presents=498 drops=2 publish_misses=0 residual=0 reason=eof tag=measured
L
run single 0 --ledger "$DIR/single.ledger"
if ! grep -q 'claim=SINGLE_LIFE' "$DIR/single.out"; then
  echo "FAIL single missing SINGLE_LIFE"; FAIL=$((FAIL+1))
fi
if ! grep -q 'SINGLE_LIFE_OK' "$DIR/single.out"; then
  echo "FAIL single missing SINGLE_LIFE_OK"; FAIL=$((FAIL+1))
fi
if grep -q 'REFUSE_SINGLE_LIFE_CLEAN' "$DIR/single.out"; then
  echo "FAIL single must not refuse"; FAIL=$((FAIL+1))
fi

# --- No sessions → refuse number ---
cat >"$DIR/empty.ledger" <<'L'
ts=2026-01-01T00:00:00Z event=process_start pid=1 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:00:01Z event=process_exit pid=1 code=0 why=site=main.cpp:--help
L
run nosess 2 --ledger "$DIR/empty.ledger"

# --- Missing file ---
run nodata 77 --ledger "$DIR/does_not_exist.ledger"

# --- RED-before-GREEN: naive tool that ignores restarts and prints clean drops ---
# A wrong implementation that only greps last drops= would "pass" multi without MULTI_LIFE.
python3 - <<'PY' >"$DIR/naive_out.txt" 2>&1
# deliberate wrong: last drops only, no restart declaration
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text() if False else 
PY
# Use shell naive wrong checker against multi ledger:
last_drops=$(grep 'event=session_end' "$DIR/multi.ledger" | tail -1 | sed -n 's/.*drops=\([0-9]*\).*/\1/p')
echo "naive_last_drops=$last_drops"
# Wrong claim would be drops=5 (last life only) without restarts_spanned.
if [ "$last_drops" = "5" ]; then
  echo "OK negative: naive last-life drops=$last_drops hides life1 drops=2 (undercount)"
else
  echo "FAIL negative setup"; FAIL=$((FAIL+1))
fi
# Product tool must NOT match naive (must sum 7, not 5)
if grep -q 'sum_drops=5' "$DIR/multi.out" && ! grep -q 'sum_drops=7' "$DIR/multi.out"; then
  echo "FAIL product collapsed to naive last-life drops"; FAIL=$((FAIL+1))
fi

# Applied-match count: MULTI_LIFE must appear exactly once in multi report
mc=$(grep -c 'claim=MULTI_LIFE' "$DIR/multi.out" || true)
echo "applied_match MULTI_LIFE count=$mc"
[ "$mc" -eq 1 ] || { echo "FAIL MULTI_LIFE count=$mc want 1"; FAIL=$((FAIL+1)); }

if [ "$FAIL" -ne 0 ]; then
  echo "test_soak_ledger_report: FAIL count=$FAIL"
  exit 1
fi
echo "test_soak_ledger_report: OK"
exit 0
