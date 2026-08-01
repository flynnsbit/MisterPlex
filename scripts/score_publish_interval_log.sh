#!/usr/bin/env bash
# Parent-only: score misterplexd publish_interval lines after a >=60s soak.
# Agent does NOT run this on the device.
#
# Usage:
#   scripts/score_publish_interval_log.sh /path/to/misterplexd.log
#   scripts/score_publish_interval_log.sh -   # stdin
#
# Pre-register bands (parent brief):
#   p_ge50 in [0.09,0.11] → ARM_LATE_MATCH_HOLD45 (late publish CONFIRMED)
#   p_ge50 < 0.03         → ARM_CLEAN (late-publish DEAD)
# Soft-skip never. true rc direct.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="${1:-}"
if [[ -z "$IN" ]]; then
  echo "usage: $0 <daemon.log|- >" >&2
  exit 2
fi

extract() {
  if [[ "$IN" == "-" ]]; then
    cat
  else
    cat "$IN"
  fi
}

# Last session_end summary wins (may have mid samples too).
LINE=$(extract | grep -E 'publish_interval notes=' | grep 'phase=session_end' | tail -n 1 || true)
if [[ -z "$LINE" ]]; then
  LINE=$(extract | grep -E 'publish_interval notes=' | tail -n 1 || true)
fi
if [[ -z "$LINE" ]]; then
  echo "FAIL: no publish_interval summary line in input" >&2
  echo "hint: deploy daemon with publish_interval ledger; end stream; grep log" >&2
  exit 1
fi

echo "SOURCE_LINE $LINE"
# Parse key=value tokens
p_ge50=$(echo "$LINE" | sed -n 's/.*p_ge50=\([0-9.]*\).*/\1/p')
sigma=$(echo "$LINE" | sed -n 's/.*sigma_ms=\([0-9.]*\).*/\1/p')
mean=$(echo "$LINE" | sed -n 's/.*mean_ms=\([0-9.]*\).*/\1/p')
verdict=$(echo "$LINE" | sed -n 's/.*verdict=\([^ ]*\).*/\1/p')
intervals=$(echo "$LINE" | sed -n 's/.*intervals=\([0-9]*\).*/\1/p')

echo "PARSED mean_ms=$mean sigma_ms=$sigma p_ge50=$p_ge50 intervals=$intervals verdict=$verdict"

# Also print companion lines if present in full log
if [[ "$IN" != "-" ]]; then
  extract | grep -E 'publish_interval_(hist|acf|corr|dump)' | tail -n 20 || true
fi

# Score bands (python for float compare)
python3 - "$p_ge50" "$sigma" "$verdict" <<'PY'
import sys
p = float(sys.argv[1]) if sys.argv[1] else float("nan")
sig = float(sys.argv[2]) if sys.argv[2] else float("nan")
v = sys.argv[3]
print("PRE-REGISTER bands:")
print("  ARM_LATE_MATCH_HOLD45: p_ge50 in [0.09, 0.11]")
print("  ARM_CLEAN:             p_ge50 < 0.03 (and sigma small / in-band)")
print(f"MEASURED p_ge50={p:.6f} sigma_ms={sig:.6f} log_verdict={v}")
if p != p:
    print("FAIL: could not parse p_ge50")
    sys.exit(1)
if 0.09 <= p <= 0.11:
    print("SCORE ARM_LATE_MATCH_HOLD45 — late ARM publish CONFIRMED (matches ~4/5-hold)")
    print("IMPLICATION: fix scheduling/CPU, NOT RTL cadence wire; FPGA decode MAY help judder")
elif p < 0.03:
    print("SCORE ARM_CLEAN — late-publish hypothesis DEAD")
    print("IMPLICATION: look vsync/present domain next (needs RBF for bank_vsync_count)")
elif 0.03 <= p < 0.09:
    print("SCORE ARM_LATE_MILD — elevated late rate, below 4/5-hold match band")
else:
    print("SCORE ARM_LATE_OR_OTHER — p_ge50 outside primary bands; inspect hist/acf")
print("OK score_publish_interval_log")
sys.exit(0)
PY
echo "score_true_rc=$?"
