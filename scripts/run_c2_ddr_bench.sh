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
GEOMETRY="${GEOMETRY:-auto}"
FORMATS="${FORMATS:-yuv420p}"
# Optional. Omit to keep bench default 0x30000000 (kDdrFrameBase). Do not
# silently retarget 1280x720 onto 720p banks. Phase 0 PL330 T_copy:
#   PHYS=0x30600000 LEN=1382400  (kDdrPl330ScratchPhys; 720p I420 bytes)
# Live 480p=0x30000000  720p Option-C=0x30180000  staging=0x30601000.
PHYS="${PHYS:-}"
LEN="${LEN:-}"
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

extra_args=()
if [[ -n "$PHYS" ]]; then
  extra_args+=(--phys "$PHYS")
fi
if [[ -n "$LEN" ]]; then
  extra_args+=(--len "$LEN")
fi

echo "host=$HOST loops=$LOOPS width=$WIDTH height=$HEIGHT geometry=$GEOMETRY formats=$FORMATS phys=${PHYS:-0x30000000} len=${LEN:-auto}"
for fmt in $FORMATS; do
  run_remote "O_SYNC /dev/mem format=$fmt" --sync --format "$fmt" --geometry "$GEOMETRY" --width "$WIDTH" --height "$HEIGHT" "${extra_args[@]}"
  run_remote "no O_SYNC /dev/mem format=$fmt" --no-sync --format "$fmt" --geometry "$GEOMETRY" --width "$WIDTH" --height "$HEIGHT" "${extra_args[@]}"
  run_remote "no O_SYNC + ARM cacheflush format=$fmt" --no-sync --flush --format "$fmt" --geometry "$GEOMETRY" --width "$WIDTH" --height "$HEIGHT" "${extra_args[@]}"
done
