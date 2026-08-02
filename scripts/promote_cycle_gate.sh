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
#   scripts/promote_cycle_gate.sh grabber-preflight [--inject-stats MIN,MAX,STD]
#   scripts/promote_cycle_gate.sh instrument min max stddev
#   scripts/promote_cycle_gate.sh instrument-class grabber_not_ready
#   scripts/promote_cycle_gate.sh frames N
#   scripts/promote_cycle_gate.sh session   # env: DELIVERY_VERIFIED FRAMES ...
#   scripts/promote_cycle_gate.sh rollback-proven BEFORE AFTER
#   scripts/promote_cycle_gate.sh ab CAND_OK PREV_OK
#   scripts/promote_cycle_gate.sh core-identity STATE
#   scripts/promote_cycle_gate.sh full-check   # all injected env; aggregate
#   scripts/promote_cycle_gate.sh clean-exit-alarm SUPERVISE_LOG_SNIPPET
#   scripts/promote_cycle_gate.sh md5-field NAME GOT WANT
#   scripts/promote_cycle_gate.sh conf-byte-exact LIVE BAK
#   scripts/promote_cycle_gate.sh evidence VIEWED GRABBER_RC
#   scripts/promote_cycle_gate.sh multishot CSV [MIN_N] [power|declare]
#
# Capture true rc= directly. rc=77 UNSCORED ≠ PASS. Never weaken.
# grabber-preflight rc=78 CAPTURE_NO_SIGNAL — do not convict device software.
# multishot: parent ~25% DEGRADED event rate — one healthy shot ≠ verified.
# evidence: viewed_pixels=0 or grabber dead → INSUFFICIENT_EVIDENCE (never proxy PASS).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

cmd="${1:-}"
shift || true

case "$cmd" in
  grabber-preflight)
    # Mandatory before any capture-based promote evidence (parent dead grabber).
    # Live: no args → tools/grabber_preflight.py --device ${HDMI_DEV:-/dev/video0}
    # Host inject RED: --inject-stats 7,7,0  → expect true rc=78
    set +e
    if [[ "${1:-}" == "--inject-stats" || "${1:-}" == "--inject-dv" || -n "${GRABBER_INJECT_STATS:-}" ]]; then
      if [[ -n "${GRABBER_INJECT_STATS:-}" && "${1:-}" != "--inject-stats" ]]; then
        python3 "$ROOT/tools/grabber_preflight.py" --inject-stats "$GRABBER_INJECT_STATS"
        rc=$?
      else
        python3 "$ROOT/tools/grabber_preflight.py" "$@"
        rc=$?
      fi
    else
      python3 "$ROOT/tools/grabber_preflight.py" --device "${HDMI_DEV:-/dev/video0}" "$@"
      rc=$?
    fi
    set -e
    case "$rc" in
      0) echo "grabber_preflight=SIGNAL_OK" ;;
      78) echo "grabber_preflight=CAPTURE_NO_SIGNAL — do NOT rollback software on this alone" ;;
      77) echo "grabber_preflight=UNSCORED — never promote PASS" ;;
      *) echo "grabber_preflight=ERR rc=$rc" ;;
    esac
    echo "true rc=$rc"
    exit "$rc"
    ;;
  clean-exit-alarm)
    # Parse supervise log lines for CLEAN_EXIT / EXIT rc=0 (S1 soak counter reset).
    # Prefer CLEAN_EXIT_BLOB= env, else file path arg, else stdin.
    text=""
    if [[ -n "${CLEAN_EXIT_BLOB:-}" ]]; then
      text=$CLEAN_EXIT_BLOB
    elif [[ -n "${1:-}" && -f "${1}" && "${1}" != "/dev/stdin" && "${1}" != "-" ]]; then
      text=$(cat -- "${1}")
    elif [[ -n "${1:-}" && "${1}" != "-" && "${1}" != "/dev/stdin" ]]; then
      text=$1
    else
      # stdin (parent: cat suplog | … clean-exit-alarm -)
      text=$(cat)
    fi
    set +e
    supervise_assert_clean_exit_alarm "$text"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  md5-field)
    set +e
    promotion_assert_md5_field "${1:-}" "${2:-}" "${3:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  conf-byte-exact)
    set +e
    promotion_assert_conf_byte_exact "${1:-}" "${2:-}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  evidence)
    set +e
    promotion_assert_evidence_sufficient "${1:-${VIEWED_PIXELS:-}}" "${2:-${GRABBER_RC:-}}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  multishot)
    set +e
    promotion_assert_multishot \
      "${1:-${MULTISHOT_RESULTS:-}}" \
      "${2:-${MULTISHOT_MIN_N:-8}}" \
      "${3:-${MULTISHOT_MODE:-power}}"
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
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
    # Aggregate: grabber-preflight → instrument → core identity → frames/session
    # Missing optional halves do not soft-pass required ones.
    rc=0
    echo "== promote_cycle full-check =="

    # Grabber preflight HARD (parent: dead grabber → innocent rollback).
    # Skip only with GRABBER_PREFLIGHT_SKIP=1 (host units); never for real promote.
    if [[ "${GRABBER_PREFLIGHT_SKIP:-0}" != "1" ]]; then
      set +e
      if [[ -n "${GRABBER_INJECT_STATS:-}" ]]; then
        python3 "$ROOT/tools/grabber_preflight.py" --inject-stats "$GRABBER_INJECT_STATS"
        grc=$?
      elif [[ -n "${GRABBER_INJECT_DV:-}" ]]; then
        python3 "$ROOT/tools/grabber_preflight.py" --inject-dv "$GRABBER_INJECT_DV"
        grc=$?
      else
        python3 "$ROOT/tools/grabber_preflight.py" --device "${HDMI_DEV:-/dev/video0}"
        grc=$?
      fi
      set -e
      echo "grabber-preflight true rc=$grc"
      if [[ "$grc" -eq 78 ]]; then
        echo "PROMOTE_OK=0 reason=CAPTURE_NO_SIGNAL"
        echo "evidence=INSUFFICIENT"
        echo "true rc=78"
        exit 78
      fi
      if [[ "$grc" -eq 77 ]]; then
        echo "PROMOTE_OK=0 reason=grabber_UNSCORED"
        echo "evidence=INSUFFICIENT"
        echo "true rc=77"
        exit 77
      fi
      if [[ "$grc" -ne 0 ]]; then
        echo "PROMOTE_OK=0 reason=grabber_preflight_fail"
        echo "evidence=INSUFFICIENT"
        echo "true rc=$grc"
        exit "$grc"
      fi
    else
      echo "NOTE GRABBER_PREFLIGHT_SKIP=1 (host unit only — never for real promote)"
    fi

    # Viewed-pixel sufficiency (parent: Pixelclock 0 → blind — never proxy PASS).
    # Real promote: set VIEWED_PIXELS=1 only after parent eyes-on glass.
    # EVIDENCE_REQUIRED=0 is host-unit only.
    if [[ "${EVIDENCE_REQUIRED:-1}" = "1" ]]; then
      set +e
      promotion_assert_evidence_sufficient "${VIEWED_PIXELS:-}" "${GRABBER_RC:-${grc:-}}"
      erc=$?
      set -e
      echo "evidence true rc=$erc"
      if [[ "$erc" -ne 0 ]]; then
        echo "PROMOTE_OK=0 reason=INSUFFICIENT_EVIDENCE"
        echo "true rc=$erc"
        exit "$erc"
      fi
    else
      echo "NOTE EVIDENCE_REQUIRED=0 (host unit only — never for real promote)"
    fi

    # Multi-shot intermittent class (parent ~25% DEGRADED).
    # CHOICE (documented): power gate default min_n=8 (~90% at p=0.25).
    # One healthy shot must NEVER be reported as verified for this class.
    # MULTISHOT_MODE=declare → honest DOES_NOT_TEST (rc=77).
    # MULTISHOT_REQUIRED=0 → host unit skip only.
    if [[ "${MULTISHOT_REQUIRED:-1}" = "1" ]]; then
      set +e
      promotion_assert_multishot \
        "${MULTISHOT_RESULTS:-}" \
        "${MULTISHOT_MIN_N:-8}" \
        "${MULTISHOT_MODE:-power}"
      mrc=$?
      set -e
      echo "multishot true rc=$mrc"
      if [[ "$mrc" -ne 0 ]]; then
        echo "PROMOTE_OK=0 reason=multishot_rc=$mrc"
        echo "true rc=$mrc"
        exit "$mrc"
      fi
    else
      echo "NOTE MULTISHOT_REQUIRED=0 (host unit only — real promote must set results or declare)"
    fi

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
    echo "usage: $0 {grabber-preflight|instrument|instrument-class|frames|session|rollback-proven|ab|core-identity|clean-exit-alarm|md5-field|conf-byte-exact|evidence|multishot|full-check}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
