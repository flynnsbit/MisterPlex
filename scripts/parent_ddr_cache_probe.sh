#!/usr/bin/env bash
# PARENT-ONLY one-shot: build static armhf bench, scp, run --matrix on MiSTer.
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

# Prefer misterplexd stopped so bank payload writes do not race the live publisher.
# Bench does NOT write doorbell magic and does NOT touch SPI.
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "chmod +x '$REMOTE' && '$REMOTE' --matrix --loops 1000 --bank 0; echo true_rc=\$?"
