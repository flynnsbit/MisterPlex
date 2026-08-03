#!/usr/bin/env bash
# files.qip must list beam RTL; product list must elaborate under PRESENT_BEAM_960.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set +e
OUT="$(python3 "$ROOT/scripts/check_present_beam_fit_elab.py" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "present_beam_fit_elab true rc=$RC"
echo "$OUT" | grep -q "CASE present_beam_fit_elab EXECUTED" || { echo "FAIL no EXECUTED" >&2; exit 2; }
echo "$OUT" | grep -q "PASS qip_lists_beam_rtl" || { echo "FAIL qip" >&2; exit 1; }
echo "$OUT" | grep -q "PASS verilator_fit_elab" || { echo "FAIL elab" >&2; exit 1; }
[[ "$RC" -eq 0 || "$RC" -eq 3 || "$RC" -eq 4 ]] || exit "$RC"
# rc 3/4 only if tools missing and not required
[[ "$RC" -eq 0 ]] || {
  if [[ "$RC" -eq 3 ]]; then
    [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  fi
  exit "$RC"
}
echo "OK test_present_beam_fit_elab"
exit 0
