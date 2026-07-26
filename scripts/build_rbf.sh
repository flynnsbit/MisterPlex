#!/usr/bin/env bash
# Build Plex.rbf using misterfpga-dev Quartus Docker image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISTER_DEV="${MISTER_DEV:-$HOME/Projects/misterfpga-dev}"
# Call scripts/mister-dev directly (bin/ symlink breaks SCRIPT_DIR for lib.sh)
MISTER_DEV_BIN="${MISTER_DEV}/scripts/mister-dev"
if [[ ! -x "$MISTER_DEV_BIN" ]]; then
  echo "mister-dev not found at $MISTER_DEV_BIN" >&2
  exit 1
fi
# Auto-find Plex.qpf; pass through extra flags (e.g. --clean)
exec "$MISTER_DEV_BIN" build "$ROOT/fpga/Plex_MiSTer" "$@"
