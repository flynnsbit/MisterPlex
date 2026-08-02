#!/usr/bin/env bash
# promote_cycle_gate.sh — host-side gates from parent 2026-08-02 deploy cycle.
#
# Lessons encoded (verbatim from parent incident):
#   1) Green host gates ≠ working build — require device-observed frames>0
#   2) Pre-flight instrument check before any promote decision
#      (min==max / stddev==0 = NO CAPTURE, not device black)
#   3) Rollback must be proven (symptom cleared under same instrument)
#   4) Two-sided A/B before convicting a build
#   + CORE_IDENTITY_UNVERIFIED → rc=2 PROMOTE_OK=0 fail-closed (never relax)
#
# Usage (parent; agents never SSH):
#   scripts/promote_cycle_gate.sh instrument min max stddev
#   scripts/promote_cycle_gate.sh instrument-class grabber_not_ready
#   scripts/promote_cycle_gate.sh frames N
#   scripts/promote_cycle_gate.sh session   # env: DELIVERY_VERIFIED FRAMES ...
#   scripts/promote_cycle_gate.sh rollback-proven BEFORE AFTER
#   scripts/promote_cycle_gate.sh ab CAND_OK PREV_OK
#   scripts/promote_cycle_gate.sh core-identity STATE
#   scripts/promote_cycle_gate.sh full-check   # all injected env; aggregate
#
# Capture true rc= directly. rc=77 UNSCORED ≠ PASS. Never weaken.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

cmd="${1:-}"
shift || true

case "$cmd" in
  instrument)
    set +e
    instrument_assert_capture_alive "${1:-}" "${2:-}" "${3:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  instrument-class)
    set +e
    instrument_assert_capture_alive "${1:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  frames)
    set +e
    promotion_assert_frames_gt0 "${1:-${FRAMES:-}}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  session)
    # Prefer promotion_session_verify.sh for log parse; this path is pure env.
    set +e
    promotion_assert_session_telemetry \
      "${DELIVERY_VERIFIED:-}" \
      "${MEASURED_DELIVERY:-}" \
      "${DROPS:-}" \
      "${UNACCOUNTED:-}" \
      "${VFPS:-}" \
      "${SOURCE_FPS:-}" \
      "${SESSION_ESTABLISHED:-}" \
      "${FRAMES:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  rollback-proven)
    set +e
    rollback_assert_proven "${1:-}" "${2:-}" "${3:-1}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  ab)
    set +e
    ab_assert_two_sided "${1:-}" "${2:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  core-identity)
    set +e
    core_identity_assert "${1:-${CORE_IDENTITY:-UNVERIFIED}}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  full-check)
    # Aggregate: instrument → core identity → frames/session → optional rollback/ab
    # Missing optional halves do not soft-pass required ones.
    rc=0
    echo "== promote_cycle full-check =="

    if [[ -n "${INSTR_MIN:-}" || -n "${INSTR_CLASS:-}" ]]; then
      set +e
      if [[ -n "${INSTR_CLASS:-}" ]]; then
        instrument_assert_capture_alive "$INSTR_CLASS"
        irc=$?
      else
        instrument_assert_capture_alive "${INSTR_MIN}" "${INSTR_MAX}" "${INSTR_STD}"
        irc=$?
      fi
      set -e
      echo "instrument true rc=$irc"
      if [[ "$irc" -eq 10 ]]; then
        echo "PROMOTE_OK=0 reason=instrument_dead"
        echo "true rc=10"
        exit 10
      fi
      [[ "$irc" -ne 0 && "$rc" -eq 0 ]] && rc=$irc
    else
      echo "FAIL instrument preflight required (set INSTR_MIN/MAX/STD or INSTR_CLASS)"
      echo "PROMOTE_OK=0 reason=instrument_missing"
      echo "true rc=4"
      exit 4
    fi

    # CORE_IDENTITY fail-closed (default UNVERIFIED)
    set +e
    core_identity_assert "${CORE_IDENTITY:-UNVERIFIED}"
    crc=$?
    set -e
    echo "core-identity true rc=$crc"
    if [[ "$crc" -eq 2 ]]; then
      echo "PROMOTE_OK=0 reason=CORE_IDENTITY_UNVERIFIED"
      # keep going to report other fails, but final rc at least 2
      [[ "$rc" -eq 0 ]] && rc=2
    fi

    set +e
    promotion_assert_session_telemetry \
      "${DELIVERY_VERIFIED:-}" \
      "${MEASURED_DELIVERY:-}" \
      "${DROPS:-0}" \
      "${UNACCOUNTED:-0}" \
      "${VFPS:-}" \
      "${SOURCE_FPS:-}" \
      "${SESSION_ESTABLISHED:-}" \
      "${FRAMES:-}"
    src=$?
    set -e
    echo "session true rc=$src"
    if [[ "$src" -eq 77 ]]; then
      echo "PROMOTE_OK=0 reason=session_UNSCORED"
      [[ "$rc" -eq 0 || "$rc" -eq 2 ]] && rc=77
    elif [[ "$src" -ne 0 ]]; then
      echo "PROMOTE_OK=0 reason=session_fail"
      [[ "$rc" -eq 0 || "$rc" -eq 2 ]] && rc=$src
    fi

    if [[ -n "${ROLLBACK_BEFORE:-}" || -n "${ROLLBACK_AFTER:-}" ]]; then
      set +e
      rollback_assert_proven "${ROLLBACK_BEFORE:-}" "${ROLLBACK_AFTER:-}" 1
      rrc=$?
      set -e
      echo "rollback-proven true rc=$rrc"
      [[ "$rrc" -ne 0 && ( "$rc" -eq 0 || "$rc" -eq 2 ) ]] && rc=$rrc
    fi

    if [[ -n "${AB_CAND:-}" || -n "${AB_PREV:-}" ]]; then
      set +e
      ab_assert_two_sided "${AB_CAND:-}" "${AB_PREV:-}"
      arc=$?
      set -e
      echo "ab true rc=$arc"
      [[ "$arc" -ne 0 && ( "$rc" -eq 0 || "$rc" -eq 2 ) ]] && rc=$arc
    fi

    if [[ "$rc" -eq 0 ]]; then
      echo "PROMOTE_CYCLE_OK"
      echo "PROMOTE_OK=1"
    else
      echo "PROMOTE_OK=0"
    fi
    echo "true rc=$rc"
    exit "$rc"
    ;;
  -h|--help|help|"")
    sed -n '2,22p' "$0" | sed 's/^# \?//'
    echo "true rc=9"
    exit 9
    ;;
  *)
    echo "usage: $0 {instrument|instrument-class|frames|session|rollback-proven|ab|core-identity|full-check}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
