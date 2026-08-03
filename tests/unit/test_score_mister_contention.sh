#!/usr/bin/env bash
# Unit: tools/score_mister_contention.py PRE_REG bands
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/score_mister_contention.py"
DIR="$ROOT/build/score_mister_$$"
mkdir -p "$DIR"
FAIL=0

mkjson() {
  # $1 path $2 mp_wf $3 ff_wf $4 mi_wf $5 mi_run
  cat >"$1" <<EOF
{
  "label": "unit",
  "dwall_s": 20,
  "misterplexd_agg": {"NO_DATA": false, "agg_wait_frac_pct": $2, "max_busy_thread_wait_frac_pct": $2, "sum_run_pct_wall": 5, "n_busy_threads": 1},
  "ffmpeg_agg": {"NO_DATA": false, "agg_wait_frac_pct": $3, "max_busy_thread_wait_frac_pct": $3, "sum_run_pct_wall": 40, "n_busy_threads": 2},
  "mister_agg": {"NO_DATA": false, "agg_wait_frac_pct": $4, "max_busy_thread_wait_frac_pct": $4, "sum_run_pct_wall": $5, "n_busy_threads": 1}
}
EOF
}

run() {
  local name="$1" want_sub="$2"
  shift 2
  out=$(python3 "$TOOL" "$@" 2>&1) || true
  st=$?
  echo "$name true rc=$st"
  echo "$out" | head -n 20
  echo "$out" | grep -q "$want_sub" || { echo "FAIL $name missing $want_sub"; FAIL=$((FAIL+1)); }
}

mkjson "$DIR/high.json" 12 20 2 50
run high_wait "CONTENTION_CONSISTENT_SUPPORT" "$DIR/high.json"

mkjson "$DIR/low.json" 1 5 2 50
run low_wait "CONTENTION_REFUTED_SUPPORT" "$DIR/low.json" --hdmi-loss-still-pct 0.70

mkjson "$DIR/ab_imp.json" 12 5 2 50
run ab_imp "CONTENTION_IMPLICATED" "$DIR/ab_imp.json" --loss-a-pct 0.70 --loss-b-pct 0.10

mkjson "$DIR/ab_elim.json" 12 5 2 50
run ab_elim "CONTENTION_ELIMINATED" "$DIR/ab_elim.json" --loss-a-pct 0.70 --loss-b-pct 0.70

if [ "$FAIL" -ne 0 ]; then
  echo "test_score_mister_contention: FAIL count=$FAIL"
  exit 1
fi
echo "test_score_mister_contention: OK"
exit 0
