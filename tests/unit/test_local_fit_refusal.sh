#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build/local_fit_refusal"
mkdir -p "$BUILD"

set +e
env -u MISTERPLEX_ALLOW_LOCAL_FIT -u MISTERPLEX_LOCAL_FIT_DRY_RUN \
  "$ROOT/scripts/build_rbf.sh" >"$BUILD/red.out" 2>&1
red_rc=$?
set -e
cat "$BUILD/red.out"
if [[ "$red_rc" -ne 75 ]]; then
  echo "FAIL local fit refusal red-check: expected rc=75, got $red_rc" >&2
  exit 1
fi
if ! grep -q 'LOCAL FIT REFUSED' "$BUILD/red.out"; then
  echo "FAIL local fit refusal red-check: missing refusal diagnostic" >&2
  exit 1
fi
if ! grep -q 'build_rbf_remote.sh slotN' "$BUILD/red.out"; then
  echo "FAIL local fit refusal red-check: missing remote-slot guidance" >&2
  exit 1
fi

MISTERPLEX_ALLOW_LOCAL_FIT=1 MISTERPLEX_LOCAL_FIT_DRY_RUN=1 \
  "$ROOT/scripts/build_rbf.sh" --clean >"$BUILD/green.out" 2>&1
cat "$BUILD/green.out"
if ! grep -q 'LOCAL FIT OVERRIDE ACCEPTED (dry-run)' "$BUILD/green.out"; then
  echo "FAIL local fit refusal green-check: override dry-run did not reach accepted path" >&2
  exit 1
fi

echo "OK local fit refusal red/green: default refuses, explicit override dry-run passes"
