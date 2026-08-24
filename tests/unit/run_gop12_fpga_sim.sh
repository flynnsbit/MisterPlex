#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/build/verilator/gop12/Vstream_path"
ANNEX="$ROOT/tests/fixtures/h264_phase1a_p16skip/plex_phase1a_p16skip_320x240_12f.264"
GOLD="$ROOT/tests/fixtures/h264_phase1a_p16skip/gold_12f_320x240.yuv"
LOG="$ROOT/build/verilator/gop12/gop12.log"
exec "$BIN" "$ANNEX" "$GOLD" | tee "$LOG"
