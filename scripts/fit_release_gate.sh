#!/usr/bin/env bash
# Fit-release gate wrapper — see scripts/fit_release_gate.py
# Usage:
#   scripts/fit_release_gate.sh [--qsf PATH]
#   scripts/fit_release_gate.sh --self-test
#   make fit-gate
#   make fit-gate-selftest
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/fit_release_gate.py" "$@"
