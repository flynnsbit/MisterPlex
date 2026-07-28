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
#   DEPLOY_RESTART_DAEMON 1 (default) | 0
#                 Restart misterplexd after a successful core load. The soft-stop
#                 below kills the painter so it is not mid-SPI during reconfiguration;
#                 without a restart the frame store has no writer and the screen is
#                 black by construction, which is indistinguishable from a core defect.
#   DEPLOY_RECOVER reboot | none  (default reboot)
#                 What to do when Main is WEDGED (accepts /dev/MiSTer_cmd writes and
#                 silently drops them). A wedged Main cannot load any core, so the only
#                 recovery is a soft reboot. MiSTer.ini is left untouched; after the
#                 reboot the core is loaded normally and re-verified.
#   DEPLOY_REBOOT_WAIT_S seconds to wait for the device to come back (default 150)
#   DEPLOY_DECODE_PROMOTION 1 to mark this deploy as an FPGA-decode promotion.
#                 Requires a recent PMS Baseline live-pass stamp from
#                 scripts/run_pms_baseline_live_gate.sh, or an explicit
#                 PMS_BASELINE_LIVE_SKIP_REASON documenting why the live gate
#                 was consciously skipped.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
DEPLOY_LOAD="${DEPLOY_LOAD:-none}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"
DEPLOY_RESTART_DAEMON="${DEPLOY_RESTART_DAEMON:-1}"
DEPLOY_RECOVER="${DEPLOY_RECOVER:-reboot}"
DEPLOY_REBOOT_WAIT_S="${DEPLOY_REBOOT_WAIT_S:-150}"
DEPLOY_DECODE_PROMOTION="${DEPLOY_DECODE_PROMOTION:-0}"
PMS_BASELINE_LIVE_STAMP="${PMS_BASELINE_LIVE_STAMP:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$DEPLOY_DECODE_PROMOTION" == "1" ]]; then
  PMS_BASELINE_LIVE_STAMP="${PMS_BASELINE_LIVE_STAMP:-$ROOT/build/pms-baseline-live-gate/PASS.stamp}"
  if [[ -s "$PMS_BASELINE_LIVE_STAMP" ]]; then
    echo "Decode promotion PMS Baseline gate: PASS stamp=$PMS_BASELINE_LIVE_STAMP"
    sed -n '1,4p' "$PMS_BASELINE_LIVE_STAMP"
  elif [[ -n "${PMS_BASELINE_LIVE_SKIP_REASON:-}" ]]; then
    echo "Decode promotion PMS Baseline gate: SKIPPED consciously: $PMS_BASELINE_LIVE_SKIP_REASON" >&2
  else
    cat >&2 <<EOF
REFUSED: DEPLOY_DECODE_PROMOTION=1 requires live PMS Baseline evidence.

Run:
  PLEX_BASE=http://plex:32400 MISTERPLEX_BASELINE_KEY=/library/metadata/N make pms-baseline-live

or set PMS_BASELINE_LIVE_SKIP_REASON with the explicit reason this decode
promotion is proceeding without live PMS Baseline/CAVLC/ref=1/no-B evidence.
EOF
    exit 4
  fi
fi

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
# Soft-stop misterplexd so it is not mid-SPI when FPGA reloads.
# Record its argv FIRST so the deploy can bring the painter back afterwards; a core
# load with no painter leaves the frame store unwritten and the screen black by
# construction, which is indistinguishable from a core defect.
rm -f /media/fat/misterplex/.deploy_last_cmdline.new
for p in $(pidof misterplexd 2>/dev/null); do
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null > /media/fat/misterplex/.deploy_last_cmdline.new
  break
done
# Only replace the recorded argv when a live one was captured, so a run made while the
# daemon is already down still has the previous invocation's flags to restore.
if [ -s /media/fat/misterplex/.deploy_last_cmdline.new ]; then
  mv -f /media/fat/misterplex/.deploy_last_cmdline.new /media/fat/misterplex/.deploy_last_cmdline
else
  rm -f /media/fat/misterplex/.deploy_last_cmdline.new
fi
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

# A wedged Main accepts /dev/MiSTer_cmd writes and drops them, so no core can be loaded
# by any means. The only recovery is a soft reboot. This is deliberately host-side: the
# remote shell dies with the reboot, so it cannot drive its own recovery.
recover_by_reboot() {
  echo "RECOVER: Main is WEDGED. Performing soft reboot (DEPLOY_RECOVER=reboot)." >&2
  echo "RECOVER: MiSTer.ini is NOT modified; the core is reloaded after the reboot." >&2
  "${SSH[@]}" 'sync; (sleep 1; reboot) >/dev/null 2>&1 &' >/dev/null 2>&1 || true

  local i down=0
  for i in $(seq 1 60); do
    "${SSH[@]}" 'true' >/dev/null 2>&1 || { down=1; echo "RECOVER: device went down after ${i}s"; break; }
    sleep 1
  done
  [ "$down" = "1" ] || echo "RECOVER: device never dropped SSH; it may not have rebooted." >&2

  local up=0
  for i in $(seq 1 "$DEPLOY_REBOOT_WAIT_S"); do
    if "${SSH[@]}" 'true' >/dev/null 2>&1; then up=1; echo "RECOVER: SSH back after ~${i}s"; break; fi
    sleep 1
  done
  if [ "$up" != "1" ]; then
    echo "RECOVER_FAIL: device did not come back within ${DEPLOY_REBOOT_WAIT_S}s." >&2
    echo "  The MiSTer needs manual power-cycling. RBF on SD is ${LOCAL_MD5}." >&2
    return 5
  fi

  # Main is fresh after reboot, so load_core is meaningful again.
  "${SSH[@]}" "bash -s" <<REMOTE
set +e
for i in \$(seq 1 30); do [ -e /dev/MiSTer_cmd ] && break; sleep 1; done
sleep 3
printf '%s\n' 'load_core /media/fat/_Utility/Plex.rbf' > /dev/MiSTer_cmd
sync
for i in \$(seq 1 $MENU_WAIT_S); do
  c=\$(cat /tmp/CORENAME 2>/dev/null || true)
  echo "CORENAME=\$c"
  if echo "\$c" | grep -qi plex; then
    echo "RECOVER_OK: Plex live after reboot"
    md5sum /media/fat/_Utility/Plex.rbf
    echo "misterplexd_pids=\$(pidof misterplexd | wc -w)"
    exit 0
  fi
  sleep 1
done
echo "RECOVER_FAIL: rebooted but Plex never came up." >&2
exit 6
REMOTE
}

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
    set +e
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
    rc=$?
    set -e
    if [ "$rc" = "3" ]; then
      if [ "$DEPLOY_RECOVER" = "reboot" ]; then
        recover_by_reboot
      else
        echo "DEPLOY_FAIL: Main wedged; DEPLOY_RECOVER=$DEPLOY_RECOVER so no recovery attempted." >&2
        exit 3
      fi
    elif [ "$rc" != "0" ]; then
      exit "$rc"
    fi
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

# --- restart the ARM painter ---
# The soft-stop above kills misterplexd on EVERY invocation (including DEPLOY_LOAD=none)
# so it is not mid-SPI during reconfiguration. Nothing used to restart it, so every
# post-deploy capture was black by construction: no painter means an unwritten frame
# store, which looks exactly like a core defect.
if [ "$DEPLOY_RESTART_DAEMON" != "0" ]; then
  set +e
  "${SSH[@]}" 'bash -s' <<'REMOTE'
set +e
D=/media/fat/misterplex
if pidof misterplexd >/dev/null 2>&1; then
  echo "DAEMON_OK: misterplexd already running pid=$(pidof misterplexd)"
  exit 0
fi
CMD=""
[ -s "$D/.deploy_last_cmdline" ] && CMD="$(cat "$D/.deploy_last_cmdline")"
if [ -z "$CMD" ]; then
  CMD="$D/bin/misterplexd --name MiSTerPlex --id misterplex-183 --port 3005 --conf $D/misterplex.conf"
  echo "DAEMON_WARN: no recorded argv; falling back to the default command line"
fi
nohup $CMD >>"$D/misterplexd.log" 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10; do
  pidof misterplexd >/dev/null 2>&1 && break
  sleep 1
done
if pidof misterplexd >/dev/null 2>&1; then
  echo "DAEMON_OK: misterplexd restarted pid=$(pidof misterplexd)"
  exit 0
fi
echo "DAEMON_FAIL: misterplexd did not come back after the core load." >&2
echo "  The frame store has no painter, so the screen will be black regardless of" >&2
echo "  the bitstream. Do NOT grade a picture from this state." >&2
exit 1
REMOTE
  drc=$?
  set -e
  if [ "$drc" != "0" ]; then
    echo "DEPLOY_WARN: core loaded but the ARM painter is down (see DAEMON_FAIL above)." >&2
  fi
fi

echo "Done."
