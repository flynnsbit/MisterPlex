#!/usr/bin/env bash
# Generate .mpx path stubs next to media files for OSD F1 "Play local (daemon)".
#
# Each .mpx contains one absolute path line to the media file. The Plex core
# loads the tiny stub via F1; misterplexd reads PLXP and plays the real path.
#
# Usage:
#   scripts/gen_mpx_sidecars.sh [/media/fat/Games/Plex]
#   scripts/gen_mpx_sidecars.sh /path/to/dir --ext mp4,mkv
set -euo pipefail

DIR="${1:-/media/fat/Games/Plex}"
shift || true
EXTS="mp4"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ext) EXTS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$DIR" ]]; then
  echo "FAIL: directory not found: $DIR" >&2
  exit 1
fi

# Resolve absolute dir (no GNU realpath required on MiSTer busybox).
DIR="$(cd "$DIR" && pwd)"
count=0
IFS=',' read -r -a ext_arr <<< "$EXTS"
for ext in "${ext_arr[@]}"; do
  ext="${ext#.}"
  shopt -s nullglob
  for f in "$DIR"/*."$ext"; do
    [[ -f "$f" ]] || continue
    stub="${f%.*}.mpx"
    # Write absolute path only (daemon rejects non-absolute).
    printf '%s\n' "$f" >"$stub"
    count=$((count + 1))
    echo "mpx: $stub -> $f"
  done
  shopt -u nullglob
done

echo "OK: wrote $count .mpx stub(s) under $DIR"
echo "OSD: F12 → Play local (daemon) → pick a .mpx entry"
