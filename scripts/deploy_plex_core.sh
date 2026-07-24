#!/usr/bin/env bash
# Deploy Plex.rbf (+ optional misterplexd) to a MiSTer over SSH.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RBF="${1:-}"
if [[ -z "$RBF" ]]; then
  for c in \
    "$ROOT/fpga/Plex_MiSTer/releases/Plex.rbf" \
    /home/shawn/Projects/misterfpga-dev/out/Plex_MiSTer/Plex.rbf \
    "$ROOT/fpga/Plex_MiSTer/output_files/Plex.rbf"
  do
    [[ -f "$c" ]] && RBF=$c && break
  done
fi
if [[ -z "${RBF:-}" || ! -f "$RBF" ]]; then
  echo "No Plex.rbf found. Build first: ./scripts/build_rbf.sh" >&2
  exit 1
fi
echo "Deploy $RBF → $USER@$HOST:/media/fat/_Utility/Plex.rbf"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$RBF" "$USER@$HOST:/media/fat/_Utility/Plex.rbf"
echo "Load core (may block if host binary wedged — power-cycle if so)"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'echo load_core /media/fat/_Utility/Plex.rbf > /dev/MiSTer_cmd' || true
echo "Done. Select Plex from OSD if load_core did not switch."
