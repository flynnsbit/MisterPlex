#!/usr/bin/env bash
# Remote compatibility entrypoint; shared transaction policy lives in rbf_build.py.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -eq 0 ]]; then
  set -- --help
fi
exec python3 "$ROOT/scripts/rbf_build.py" remote "$@"
