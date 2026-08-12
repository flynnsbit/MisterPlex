#!/usr/bin/env bash
# POS/NEG controls for scripts/check_decoder_conformance.py (harness framework).
# Soft-skip (77) is NOT a pass. Report runner conclusions, never grep bare FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_decoder_conformance.py"

echo "EXECUTED test_decoder_conformance_harness"

set +e
out=$(python3 "$GATE" --self-test --root "$ROOT" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's|^|  |'
echo "true rc=$rc"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL test_decoder_conformance_harness: self-test rc=$rc" >&2
  exit 1
fi
grep -q "EXECUTED check_decoder_conformance --self-test" <<<"$out" || {
  echo "FAIL: self-test must print EXECUTED" >&2
  exit 1
}
grep -q "PASS decoder_conformance self-test" <<<"$out" || {
  echo "FAIL: self-test must print PASS conclusion" >&2
  exit 1
}
grep -q "SELFTEST POS_compare_identical: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_compare_identical" >&2
  exit 1
}
grep -q "SELFTEST NEG_compare_first_divergence: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_compare_first_divergence" >&2
  exit 1
}
grep -q "SELFTEST NEG_tautological_same_path: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_tautological_same_path" >&2
  exit 1
}
grep -q "SELFTEST POS_corpus_non_dev: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_corpus_non_dev" >&2
  exit 1
}
grep -q "SELFTEST NEG_corpus_dev_only_claim: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_corpus_dev_only_claim" >&2
  exit 1
}
grep -q "SELFTEST POS_coverage_honest_incomplete: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_coverage" >&2
  exit 1
}
grep -q "SELFTEST NEG_coverage_empty_complete: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_coverage_empty_complete" >&2
  exit 1
}
grep -q "SELFTEST NEG_coverage_unproven_complete: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_coverage_unproven" >&2
  exit 1
}
grep -q "SELFTEST POS_reachability_empty_claims: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_reachability" >&2
  exit 1
}
grep -q "SELFTEST NEG_reachability_claim_pruned_h264: rc=0" <<<"$out" || {
  echo "FAIL: missing NEG_reachability_claim_pruned" >&2
  exit 1
}
grep -q "SELFTEST POS_live_gate_no_claims: rc=0" <<<"$out" || {
  echo "FAIL: missing POS_live_gate" >&2
  exit 1
}
grep -q "first_divergence mb_index=1" <<<"$out" || {
  echo "FAIL: first-divergence must name mb_index=1" >&2
  exit 1
}

# Live gate (product fixtures) — separate direct rc capture
set +e
gate_out=$(python3 "$GATE" --gate --root "$ROOT" 2>&1)
gate_rc=$?
set -e
printf '%s\n' "$gate_out" | sed 's|^|  gate: |'
echo "true gate_rc=$gate_rc"
if [[ "$gate_rc" -ne 0 ]]; then
  echo "FAIL live decoder-conformance gate rc=$gate_rc" >&2
  exit 1
fi
grep -q "PASS decoder_conformance gate" <<<"$gate_out" || {
  echo "FAIL: live gate missing PASS conclusion" >&2
  exit 1
}

# Explicit NEG control outside self-test: claim pruned module on CLI
set +e
neg_out=$(python3 "$GATE" reachability --root "$ROOT" --modules h264_cavlc_residual_block 2>&1)
neg_rc=$?
set -e
printf '%s\n' "$neg_out" | sed 's|^|  neg_r: |'
echo "true neg_reachability_rc=$neg_rc"
if [[ "$neg_rc" -eq 0 ]]; then
  echo "FAIL: claiming pruned h264 module must not PASS" >&2
  exit 1
fi
grep -q "FAIL decoder_reachability" <<<"$neg_out" || {
  echo "FAIL: expected FAIL decoder_reachability conclusion" >&2
  exit 1
}
echo "EXPECTED_RED decoder_reachability_claim_pruned: rc=$neg_rc"

echo "test_decoder_conformance_harness: OK"
