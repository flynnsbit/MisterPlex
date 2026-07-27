#!/usr/bin/env bash
# Build Plex.rbf using misterfpga-dev Quartus Docker image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISTER_DEV="${MISTER_DEV:-$HOME/Projects/misterfpga-dev}"

if [[ "${MISTERPLEX_ALLOW_LOCAL_FIT:-0}" != "1" ]]; then
  cat >&2 <<'FAIL'
LOCAL FIT REFUSED: local Quartus fitting is closed on this workstation.

Use an isolated remote slot instead:
  scripts/build_rbf_remote.sh slotN

Running Quartus locally has produced memory pressure that makes Verilator results
unreliable. To run a local fit anyway with explicit parent approval:
  MISTERPLEX_ALLOW_LOCAL_FIT=1 scripts/build_rbf.sh
FAIL
  exit 75
fi

# Call scripts/mister-dev directly (bin/ symlink breaks SCRIPT_DIR for lib.sh)
MISTER_DEV_BIN="${MISTER_DEV}/scripts/mister-dev"
if [[ ! -x "$MISTER_DEV_BIN" ]]; then
  echo "mister-dev not found at $MISTER_DEV_BIN" >&2
  exit 1
fi

if [[ "${MISTERPLEX_LOCAL_FIT_DRY_RUN:-0}" == "1" ]]; then
  printf 'LOCAL FIT OVERRIDE ACCEPTED (dry-run): %q build %q' "$MISTER_DEV_BIN" "$ROOT/fpga/Plex_MiSTer"
  printf ' %q' "$@"
  printf '\n'
  exit 0
fi

# Auto-find Plex.qpf; pass through extra flags (e.g. --clean)
exec "$MISTER_DEV_BIN" build "$ROOT/fpga/Plex_MiSTer" "$@"
