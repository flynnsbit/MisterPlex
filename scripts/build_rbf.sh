#!/usr/bin/env bash
# Build Plex.rbf using misterfpga-dev Quartus Docker image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISTER_DEV="${MISTER_DEV:-/home/shawn/Projects/misterfpga-dev}"
export PATH="$MISTER_DEV/bin:$PATH"
if ! command -v mister-dev >/dev/null 2>&1; then
  echo "mister-dev not found; run $MISTER_DEV/scripts/mister-dev setup" >&2
  exit 1
fi
exec mister-dev build "$ROOT/fpga/Plex_MiSTer" --qpf Plex "$@"
