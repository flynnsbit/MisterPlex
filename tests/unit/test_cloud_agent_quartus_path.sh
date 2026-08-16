#!/usr/bin/env bash
# RED/GREEN: Cloud Agent PATH restore must not invent quartus_sh, and must
# prepend $QUARTUS_ROOTDIR/bin when that directory exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build/cloud-agent-quartus-path"
rm -rf "$WORK"
mkdir -p "$WORK/good/bin" "$WORK/empty"

(
  PATH="/usr/bin:/bin"
  unset QUARTUS_PATH QUARTUS_ROOTDIR SOPC_KIT_NIOS2
  QUARTUS_PATH="$WORK/empty"
  QUARTUS_ROOTDIR="$WORK/empty"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/cloud-agent-quartus-env.sh"
  if command -v quartus_sh >/dev/null 2>&1; then
    echo "FAIL: empty QUARTUS_ROOTDIR unexpectedly found quartus_sh" >&2
    echo "PATH=$PATH" >&2
    exit 1
  fi
)
echo "RED OK: missing bindir does not invent quartus_sh"

printf '%s\n' '#!/bin/sh' 'echo Quartus Prime Shell' 'echo Version 17.0.2 Build 602' \
  >"$WORK/good/bin/quartus_sh"
chmod +x "$WORK/good/bin/quartus_sh"

(
  PATH="/usr/bin:/bin"
  unset QUARTUS_PATH QUARTUS_ROOTDIR SOPC_KIT_NIOS2
  QUARTUS_PATH="$WORK/good"
  QUARTUS_ROOTDIR="$WORK/good"
  # shellcheck source=/dev/null
  . "$ROOT/scripts/cloud-agent-quartus-env.sh"
  got="$(command -v quartus_sh || true)"
  if [[ "$got" != "$WORK/good/bin/quartus_sh" ]]; then
    echo "FAIL: expected $WORK/good/bin/quartus_sh, got ${got:-none}" >&2
    echo "PATH=$PATH" >&2
    exit 1
  fi
)
echo "GREEN OK: prepended QUARTUS_ROOTDIR/bin"
