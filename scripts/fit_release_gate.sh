#!/usr/bin/env bash
# Fit-release gate wrapper — see scripts/fit_release_gate.py
# Usage:
#   scripts/fit_release_gate.sh [--root MERGE_TREE] [--qsf PATH]
#   scripts/fit_release_gate.sh --print-integration-help
# Integration (w-osd): run THIS ruler against a merged tree:
#   $FITGATE/scripts/fit_release_gate.sh --root $MERGE --qsf $MERGE/fpga/Plex_MiSTer/Plex.qsf
#   scripts/fit_release_gate.sh --self-test
#   make fit-gate
#   make fit-gate-selftest
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/fit_release_gate.py" "$@"
