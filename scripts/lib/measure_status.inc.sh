#!/usr/bin/env bash
# measure_status.inc.sh — three-way measurement outcomes for shell gates.
#
# Rule (parent 2026-07-31, generalises all session instrument artifacts):
#   An absence of evidence must NEVER be encoded as a measured value.
#   Outcomes: MEASURED_VALUE | MEASURED_ABSENCE | COULD_NOT_MEASURE
#   COULD_NOT_MEASURE must not collapse into 0 / empty-as-ok / PASS.
#
# Shell equivalent of Python instrument UNSCORED (rc=77) for "not scored",
# and NO-DATA (rc=4) for transport/probe failure. HARD FAIL (rc=3/4) when a
# path claims timing/liveness closure without a readable subject.
#
# Source: source scripts/lib/measure_status.inc.sh

# grep -c with three-way outcome.
# Usage: measure_grep_count <pattern> <file>
# Prints:
#   MEASURE_STATUS=MEASURED|NO_DATA
#   MEASURE_COUNT=<int>          # only when MEASURED (0 = measured absence of matches)
#   MEASURE_REASON=...           # when NO_DATA
# rc: 0 MEASURED (including count 0), 4 NO_DATA (absent/unreadable/grep error)
measure_grep_count() {
  local pat="${1:-}" file="${2:-}" n rc
  if [ -z "$pat" ] || [ -z "$file" ]; then
    echo "MEASURE_STATUS=NO_DATA"
    echo "MEASURE_REASON=missing_args"
    return 4
  fi
  if [ ! -e "$file" ]; then
    echo "MEASURE_STATUS=NO_DATA"
    echo "MEASURE_REASON=absent path=$file"
    return 4
  fi
  if [ ! -r "$file" ]; then
    echo "MEASURE_STATUS=NO_DATA"
    echo "MEASURE_REASON=unreadable path=$file"
    return 4
  fi
  set +e
  n=$(grep -cE "$pat" "$file" 2>/dev/null)
  rc=$?
  set -e
  # GNU grep: 0=matches, 1=no matches, 2=error. BusyBox similar.
  if [ "$rc" -ge 2 ]; then
    echo "MEASURE_STATUS=NO_DATA"
    echo "MEASURE_REASON=grep_error rc=$rc path=$file"
    return 4
  fi
  # grep -c may print nothing on some errors; empty is NO_DATA not zero.
  if [ -z "$n" ]; then
    echo "MEASURE_STATUS=NO_DATA"
    echo "MEASURE_REASON=empty_count path=$file"
    return 4
  fi
  case "$n" in
    ''|*[!0-9]*)
      echo "MEASURE_STATUS=NO_DATA"
      echo "MEASURE_REASON=bad_count got='$n' path=$file"
      return 4
      ;;
  esac
  echo "MEASURE_STATUS=MEASURED"
  echo "MEASURE_COUNT=$n"
  return 0
}

# STA negative-slack rows. Absent/unreadable STA is HARD FAIL material for build.
# Prints same MEASURE_* keys; rc 0 measured, 4 no-data.
measure_sta_neg_slack() {
  local sta="${1:-}"
  # Quartus slack cells look like: ; -0.123 ;
  measure_grep_count ';[[:space:]]*-[0-9]+\.[0-9]+[[:space:]]*;' "$sta"
}

# Banned collapse patterns (for static guards / docs).
measure_status_banned_doc() {
  cat <<'EOF'
BANNED (absence → measured zero):
  count="$(grep -c pat file || true)"
  count="$(grep -c pat file || echo 0)"
  n=$(pidof foo | wc -w)          # empty pidof → 0 processes "measured"
REQUIRED:
  measure_grep_count / explicit [ -r file ] then grep -c; rc>=2 or missing → NO_DATA
  never claim timing closure / liveness from NO_DATA
EOF
}
