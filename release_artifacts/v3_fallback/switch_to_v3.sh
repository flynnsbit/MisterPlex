#!/usr/bin/env bash
# Stop the DEV daemon (/media/fat/misterplex) and start the v3 fallback daemon.
# Does NOT overwrite any files under /media/fat/misterplex/ or Plex.rbf.
# Core load: parent/user selects Plex_v3 from the MiSTer OSD (_Utility/Plex_v3.rbf).
set -euo pipefail

V3_ROOT="${MISTERPLEX_V3_ROOT:-/media/fat/misterplex_v3}"
DEV_ROOT="${MISTERPLEX_DEV_ROOT:-/media/fat/misterplex}"

echo "switch_to_v3: stopping any misterplexd / ffmpeg ..."
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill "$p" 2>/dev/null || true
done
sleep 0.5
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.3

# Never delete/modify dev tree — only ensure it is not running.
if [[ -d "$DEV_ROOT" ]]; then
  echo "switch_to_v3: left $DEV_ROOT untouched (dev install preserved)"
fi

bash "$V3_ROOT/scripts/run_misterplexd_v3.sh"
echo "switch_to_v3: DONE — load core /media/fat/_Utility/Plex_v3.rbf from OSD if not already loaded"
echo "switch_to_v3: healthy log greps:"
echo "  grep -E 'FPGA frame path OK|GDM: listening|companion: GDM' $V3_ROOT/misterplexd.log | tail"
