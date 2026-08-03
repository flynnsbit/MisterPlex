#!/usr/bin/env bash
# Run Verilator from a scoped userspace OSS CAD Suite install without sourcing its
# environment globally or changing the caller's shell/toolchain PATH.
#
# HARD RULE: -Wno-fatal must never turn elab/link pin errors into a green build.
# PINNOTFOUND / %Error on the fitted RTL is LOUD RED (rc=2), not a skip or pass.
# Soft-skip (rc=77) is only for missing Verilator binary (caller's choice).
set -euo pipefail

resolve_verilator() {
  if [[ -n "${VERILATOR:-}" ]]; then
    if [[ ! -x "$VERILATOR" ]]; then
      echo "run_verilator: VERILATOR is not executable: $VERILATOR" >&2
      exit 2
    fi
    printf '%s\n' "$VERILATOR"
    return
  fi
  OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite}"
  if [[ -x "$OSS_CAD_SUITE/bin/verilator" ]]; then
    printf '%s\n' "$OSS_CAD_SUITE/bin/verilator"
    return
  fi
  if command -v verilator >/dev/null 2>&1; then
    command -v verilator
    return
  fi
  echo "run_verilator: Verilator not found. Install oss-cad-suite under ~/.local/oss-cad-suite or set VERILATOR=/path/to/verilator." >&2
  exit 127
}

VL="$(resolve_verilator)"
if [[ "$VL" == *oss-cad-suite* ]]; then
  export PATH="$(dirname "$VL"):${PATH:-}"
fi

# Prefer project-local scratch (repo forbids /tmp writes in agent context).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGDIR="$ROOT/.agent-work/verilator-run-logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/run-$$.log"
cleanup() { rm -f "$LOG"; }
trap cleanup EXIT

set +e
"$VL" "$@" >"$LOG" 2>&1
VL_RC=$?
set -e
cat "$LOG"

if grep -E -q \
  '%Error(-[A-Z0-9]+)?:|PINNOTFOUND|%Error-PINNOTFOUND|Undefined variable|syntax error|Can.t find file' \
  "$LOG"; then
  echo "run_verilator: HARD FAIL — Verilator reported elab/bind/compile error (PINNOTFOUND/%Error). Not a pass, not a skip." >&2
  grep -E '%Error|PINNOTFOUND|Undefined variable|syntax error|Can.t find file' "$LOG" | head -40 >&2 || true
  exit 2
fi

exit "$VL_RC"
