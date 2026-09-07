#!/usr/bin/env bash
# Explicit backend selection; neither backend promotes or deploys an RBF.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: scripts/build_rbf.sh --backend remote SLOT [PROJECT_PATH] [--derive-video-build-id]
       MISTERPLEX_ALLOW_LOCAL_FIT=1 scripts/build_rbf.sh --backend local-container SLOT [PROJECT_PATH] [--derive-video-build-id]

No backend/default invocation remains refused. Local permission alone is not
backend selection. See docs/rtl-simulation.md for the serial snapshot procedure.
--derive-video-build-id renders FPGA_VIDEO_BUILD_ID from original source identity;
without it, legacy/oldbaseline video identity, tool, seed and processor defaults remain unchanged.
EOF
  exit 0
fi
if [[ "${1:-}" != "--backend" ]]; then
  cat >&2 <<'EOF'
REFUSED: local Quartus fits are not permitted in this project.

Default policy remains remote-only:
    scripts/build_rbf_remote.sh slotN

The sole lab operator may deliberately select --backend local-container WITH
MISTERPLEX_ALLOW_LOCAL_FIT=1. Never run Verilator tests during that local fit.
Do not change the image, seed or processor count between reproducibility runs.
EOF
  exit 3
fi
backend="${2:-}"
if [[ $# -lt 2 ]]; then
  echo "--backend requires remote or local-container" >&2
  exit 2
fi
shift 2
case "$backend" in
  remote) exec "$ROOT/scripts/build_rbf_remote.sh" "$@" ;;
  local-container)
    if [[ "${MISTERPLEX_ALLOW_LOCAL_FIT:-0}" != "1" ]]; then
      echo "REFUSED: explicit local-container backend also requires MISTERPLEX_ALLOW_LOCAL_FIT=1." >&2
      exit 3
    fi
    exec python3 "$ROOT/scripts/rbf_build.py" local-container "$@"
    ;;
  *) echo "Unknown build backend: $backend" >&2; exit 2 ;;
esac
