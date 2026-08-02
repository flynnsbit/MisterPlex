#!/usr/bin/env bash
# run_480p_matrix.sh — sequential 480p client-truth arms (healthy + collapse case).
#
# Default order: rk=27 FullBleed (healthy) then rk=9 BBB 624x352 (collapse case).
# Each arm is a separate suite process with clean teardown (daily driver safe).
# Matrix exit = first non-zero arm rc (does not soft-pass a failed arm).
#
# Parent runs; agent-run ≠ evidence. Capture: cmd; echo "true rc=$?"
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"

if [[ $# -gt 0 ]]; then
  LIST=("$@")
else
  LIST=(fullbleed bbb352)
fi

echo "E2E_480P_MATRIX begin arms=${LIST[*]}"
echo "E2E_480P_MATRIX_PREREG:"
echo "  each arm: CAST_PICKER_E2E_RESULT + CLIENT_RATE + COMPANION_INVARIANT + TEARDOWN_OK"
echo "  matrix FAIL if any arm FAIL; SKIP-NOT-PASS never reported as PASS"

final_rc=0
for arm in "${LIST[@]}"; do
  out="$REPO/build/e2e-480p-matrix-${arm}"
  mkdir -p "$out"
  echo "---- ARM ${arm} out=${out} ----"
  E2E_OUT="$out" bash "$ROOT/run_480p_client_truth.sh" "$arm"
  rc=$?
  echo "ARM_${arm}_true_rc=${rc}"
  if [[ "$rc" -ne 0 && "$final_rc" -eq 0 ]]; then
    final_rc=$rc
  fi
done

echo "E2E_480P_MATRIX_DONE final_rc=${final_rc} arms=${LIST[*]}"
if [[ "$final_rc" -eq 0 ]]; then
  echo "CAST_PICKER_E2E_RESULT=PASS summary=480p_matrix_all_arms"
else
  echo "CAST_PICKER_E2E_RESULT=FAIL summary=480p_matrix_arm_failed rc=${final_rc}"
fi
exit "$final_rc"
