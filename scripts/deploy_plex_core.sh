#!/usr/bin/env bash
# Safe Plex.rbf deploy to MiSTer — avoids lockups from:
#   - overwriting the live RBF while the core is running + load_core
#   - kill -9 misterplexd / SPI thrash concurrent with Main load_core
#   - flooding /dev/MiSTer_cmd while SPI exclusive pause is held
#
# Usage:
#   ./scripts/deploy_plex_core.sh [path/to/Plex.rbf]
#
# Env:
#   MISTER_HOST   default 192.168.1.183
#   MISTER_PASS   default 1
#   DEPLOY_LOAD   none | menu | core
#                 none (default) — copy only; leave running core alone (safest)
#                 menu           — load Menu, wait, then load Plex (safer switch)
#                 core           — load Plex only (use when already on Menu)
#   DEPLOY_WAIT_S settle after load_core (default 5)
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
DEPLOY_LOAD="${DEPLOY_LOAD:-none}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RBF="${1:-}"
if [[ -z "$RBF" ]]; then
  for c in \
    "$ROOT/fpga/Plex_MiSTer/output_files/Plex.rbf" \
    "$ROOT/fpga/Plex_MiSTer/releases/Plex.rbf" \
    "${MISTER_DEV:-$HOME/Projects/misterfpga-dev}/out/Plex_MiSTer/Plex.rbf"
  do
    [[ -f "$c" ]] && RBF=$c && break
  done
fi
if [[ -z "${RBF:-}" || ! -f "$RBF" ]]; then
  echo "No Plex.rbf found. Build first: ./scripts/build_rbf.sh" >&2
  exit 1
fi

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -o ServerAliveInterval=3 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

LOCAL_MD5=$(md5sum "$RBF" | awk '{print $1}')
echo "Deploy $RBF (md5=$LOCAL_MD5)"
echo "  host=$USER@$HOST  load=$DEPLOY_LOAD"

# --- remote prep: release SPI, soft-stop companion (never -9 first) ---
"${SSH[@]}" 'bash -s' <<'REMOTE'
set +e
# Drop any SPI flock holders gently
if [ -f /tmp/misterplex_spi.lock ]; then
  # processes blocking on flock — TERM only
  for p in $(ps | grep -E '[s]et_status|[p]ush_frame' | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  sleep 0.3
  rm -f /tmp/misterplex_spi.lock
fi
# Soft-stop misterplexd so it is not mid-SPI when FPGA reloads
if ps | grep -v grep | grep -q '[m]isterplexd'; then
  killall misterplexd 2>/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    ps | grep -v grep | grep -q '[m]isterplexd' || break
    sleep 0.25
  done
  # only if still up
  if ps | grep -v grep | grep -q '[m]isterplexd'; then
    killall -9 misterplexd 2>/dev/null
  fi
fi
# Ensure Main is not left SIGSTOP'd from a crashed SpiExclusive
killall -CONT MiSTer 2>/dev/null
killall -CONT MiSTer_groovy 2>/dev/null
sync
REMOTE

REMOTE_MD5=$("${SSH[@]}" 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' | awk '{print $1}' || true)
if [[ -n "${REMOTE_MD5:-}" && "$REMOTE_MD5" == "$LOCAL_MD5" ]]; then
  echo "Remote already has md5=$REMOTE_MD5 — skip scp"
else
  # Stage then atomic replace (never scp onto the open/running name mid-read)
  STAGED="/media/fat/_Utility/Plex.new.$$.rbf"
  FINAL="/media/fat/_Utility/Plex.rbf"
  echo "SCP → $STAGED"
  "${SCP[@]}" "$RBF" "$USER@$HOST:$STAGED"
  "${SSH[@]}" "bash -s" <<REMOTE
set -e
sync
# Prefer rename over in-place overwrite of a core that may still be mapped
if [ -f "$FINAL" ]; then
  mv -f "$FINAL" "${FINAL}.bak" 2>/dev/null || true
fi
mv -f "$STAGED" "$FINAL"
chmod 755 "$FINAL"
sync
md5sum "$FINAL"
REMOTE
fi

# Core reconfiguration takes several seconds; the liveness probe needs a longer window
# than the post-load settle time so a healthy Main is never mistaken for a wedged one.
MENU_WAIT_S="$DEPLOY_WAIT_S"; [ "$MENU_WAIT_S" -ge 20 ] || MENU_WAIT_S=20

case "$DEPLOY_LOAD" in
  none|0|off|copy)
    echo "DEPLOY_LOAD=none — RBF on SD only; not calling load_core (safest)."
    echo "Select Plex from the OSD, or re-run with DEPLOY_LOAD=menu."
    ;;
  menu|bounce)
    echo "Soft reload: Menu → wait → Plex"
    # The MENU step is also the ONLY valid Main liveness test. A wedged Main accepts
    # /dev/MiSTer_cmd writes and drops them: the RBF on SD updates (md5 verifies!) but the
    # FPGA keeps running the bitstream loaded when Main wedged. Reaching CORENAME=Plex at
    # the end proves nothing on its own, because Plex may simply never have been unloaded.
    "${SSH[@]}" "bash -s" <<REMOTE
set +e
printf '%s\n' 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd
sync
menu_ok=0
for i in \$(seq 1 $MENU_WAIT_S); do
  c=\$(cat /tmp/CORENAME 2>/dev/null || true)
  echo "CORENAME=\$c"
  if echo "\$c" | grep -qi menu; then menu_ok=1; break; fi
  sleep 1
done
if [ "\$menu_ok" != "1" ]; then
  echo "DEPLOY_FAIL: Main never switched to MENU — it is WEDGED and is silently ignoring" >&2
  echo "  /dev/MiSTer_cmd. The new RBF is on the SD card but the FPGA is STILL RUNNING THE" >&2
  echo "  OLD BITSTREAM. Do not test this build. Reboot the MiSTer, then redeploy." >&2
  exit 3
fi
printf '%s\n' 'load_core /media/fat/_Utility/Plex.rbf' > /dev/MiSTer_cmd
sync
for i in \$(seq 1 $MENU_WAIT_S); do
  c=\$(cat /tmp/CORENAME 2>/dev/null || true)
  echo "CORENAME=\$c"
  echo "\$c" | grep -qi plex && exit 0
  sleep 1
done
echo "DEPLOY_FAIL: Main accepted MENU but never came back to Plex." >&2
exit 4
REMOTE
    ;;
  core|plex|1)
    echo "Reload Plex only (prefer when already on Menu)"
    "${SSH[@]}" "bash -s" <<REMOTE
set +e
printf '%s\n' 'load_core /media/fat/_Utility/Plex.rbf' > /dev/MiSTer_cmd
sync
for i in \$(seq 1 $DEPLOY_WAIT_S); do
  c=\$(cat /tmp/CORENAME 2>/dev/null || true)
  echo "CORENAME=\$c"
  echo "\$c" | grep -qi plex && break
  sleep 1
done
REMOTE
    ;;
  *)
    echo "Unknown DEPLOY_LOAD=$DEPLOY_LOAD (use none|menu|core)" >&2
    exit 2
    ;;
esac

echo "Done."
