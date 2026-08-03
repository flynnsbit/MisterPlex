#!/usr/bin/env bash
# Red-before-green for scripts/parent_playing_gate.sh (no MiSTer required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/parent_playing_gate.sh"
EV="$ROOT/build/parent_playing_gate_test"
mkdir -p "$EV"
export EV_DIR="$EV/run-$$"
rm -rf "$EV_DIR"
mkdir -p "$EV_DIR"

set +e
out="$("$GATE" offline-selftest 2>&1)"
rc=$?
set -e
echo "$out"
echo "offline-selftest: true rc=$rc"
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL test_parent_playing_gate offline-selftest" >&2
  exit 1
fi
if ! grep -q 'OFFLINE_SELFTEST_OK' <<<"$out"; then
  echo "FAIL missing OFFLINE_SELFTEST_OK" >&2
  exit 1
fi
echo "OK test_parent_playing_gate"
exit 0
