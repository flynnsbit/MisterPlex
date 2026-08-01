# gate_coverage.inc.sh — publish no gate result without its coverage.
#
# Fleet rule (parent 2026-08-01): rc=0 over an empty inspection set is UNSCORED,
# never PASS. A gate that returns 0 while not looking manufactures confidence.
#
# Usage:
#   source scripts/lib/gate_coverage.inc.sh
#   gate_coverage_begin "my-gate"
#   gate_coverage_note "deploy_live_md5" "inspected /proc/PID/exe md5"
#   gate_coverage_note "deploy_http" "GET :3005/resources"
#   gate_coverage_finish 0   # → PASS only if notes>0; else UNSCORED rc=77
#
# shellcheck shell=bash

GATE_COVERAGE_NAME=""
GATE_COVERAGE_NOTES=0
GATE_COVERAGE_LINES=()

gate_coverage_begin() {
  GATE_COVERAGE_NAME="${1:-gate}"
  GATE_COVERAGE_NOTES=0
  GATE_COVERAGE_LINES=()
  echo "GATE_COVERAGE_BEGIN name=${GATE_COVERAGE_NAME}"
}

gate_coverage_note() {
  local id="${1:?id}" detail="${2:-}"
  GATE_COVERAGE_NOTES=$((GATE_COVERAGE_NOTES + 1))
  GATE_COVERAGE_LINES+=("GATE_COVERAGE_ITEM id=${id} detail=${detail}")
  echo "GATE_COVERAGE_ITEM id=${id} detail=${detail}"
}

# gate_coverage_finish WRAPPED_RC
#   If WRAPPED_RC==0 and NOTES==0 → print UNSCORED and return 77.
#   If WRAPPED_RC==0 and NOTES>0  → print PASS with coverage count, return 0.
#   Else return WRAPPED_RC unchanged (still print coverage table).
gate_coverage_finish() {
  local wrapped="${1:-1}"
  local i
  echo "GATE_COVERAGE_END name=${GATE_COVERAGE_NAME} inspected_count=${GATE_COVERAGE_NOTES}"
  if [[ "$wrapped" -eq 0 && "$GATE_COVERAGE_NOTES" -eq 0 ]]; then
    echo "verdict=UNSCORED reason=empty_inspection_set gate=${GATE_COVERAGE_NAME}"
    echo "true rc=77"
    return 77
  fi
  if [[ "$wrapped" -eq 0 ]]; then
    echo "verdict=PASS coverage_count=${GATE_COVERAGE_NOTES} gate=${GATE_COVERAGE_NAME}"
    echo "true rc=0"
    return 0
  fi
  echo "verdict=FAIL wrapped_rc=${wrapped} coverage_count=${GATE_COVERAGE_NOTES} gate=${GATE_COVERAGE_NAME}"
  echo "true rc=${wrapped}"
  return "$wrapped"
}
