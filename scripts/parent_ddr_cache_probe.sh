#!/usr/bin/env bash
# PARENT-ONLY: copy arm ddr_write_bench and run cache-policy matrix on MiSTer.
# Workers must not execute this (no device access rule).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
REMOTE="/media/fat/misterplex/bin/ddr_write_bench"

make -C "$ROOT" arm-ddr-bench
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
  "$ROOT/build/arm/ddr_write_bench" "$USER@$HOST:$REMOTE"

run() {
  local label="$1"; shift
  echo "=== $label ==="
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    "chmod +x '$REMOTE' && '$REMOTE' $*"
  echo "(parent: capture rc from ssh itself)"
}

run "A devmem O_SYNC 624x480" --sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
run "B devmem no-sync 624x480" --no-sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
run "C devmem no-sync+flush 624x480" --no-sync --flush --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
run "D devmem O_SYNC 320x240" --sync --format yuv420p --width 320 --height 240 --loops 1000 --bank 0
run "E fb0 control 320x240" --fb-copy --format yuv420p --width 320 --height 240 --loops 1000
