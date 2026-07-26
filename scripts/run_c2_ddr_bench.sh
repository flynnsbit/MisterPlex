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

echo "host=$HOST loops=$LOOPS frame_bytes=153600"
run_remote "O_SYNC /dev/mem (current product mapping)" --sync
run_remote "no O_SYNC /dev/mem" --no-sync
run_remote "no O_SYNC + ARM cacheflush" --no-sync --flush
