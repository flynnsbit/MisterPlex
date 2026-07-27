#!/usr/bin/env bash
# Build, copy, and run the C2 DDR write microbenchmark on the MiSTer.
# Requires the parent deploy/measurement token; this script writes only the DDR
# frame window and never touches SPI or restarts misterplexd.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
LOOPS="${LOOPS:-1000}"
WIDTH="${WIDTH:-320}"
HEIGHT="${HEIGHT:-240}"
FORMATS="${FORMATS:-rgb565}"
REMOTE="/media/fat/misterplex/bin/ddr_write_bench"

make -C "$ROOT" arm-ddr-bench >/dev/null
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
  "$ROOT/build/arm/ddr_write_bench" "$USER@$HOST:$REMOTE" >/dev/null

run_remote() {
  local label="$1"
  shift
  echo "=== $label ==="
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
    "chmod +x '$REMOTE' && '$REMOTE' --loops '$LOOPS' $*"
}

echo "host=$HOST loops=$LOOPS width=$WIDTH height=$HEIGHT formats=$FORMATS"
for fmt in $FORMATS; do
  run_remote "O_SYNC /dev/mem format=$fmt" --sync --format "$fmt" --width "$WIDTH" --height "$HEIGHT"
  run_remote "no O_SYNC /dev/mem format=$fmt" --no-sync --format "$fmt" --width "$WIDTH" --height "$HEIGHT"
  run_remote "no O_SYNC + ARM cacheflush format=$fmt" --no-sync --flush --format "$fmt" --width "$WIDTH" --height "$HEIGHT"
done
