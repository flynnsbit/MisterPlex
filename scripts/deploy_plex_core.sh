#!/usr/bin/env bash
# Safe Plex.rbf deploy to MiSTer — avoids lockups from:
#   - overwriting the live RBF while the core is running + load_core
#   - kill -9 misterplexd / SPI thrash concurrent with Main load_core
#   - flooding /dev/MiSTer_cmd while SPI exclusive pause is held
#
# Usage:
#   ./scripts/deploy_plex_core.sh [path/to/Plex.rbf]
#   ./scripts/deploy_plex_core.sh --help
#
# Ban (before any scp/menu): after LOCAL_MD5, source
# tests/unit/test_phase1a_rbf_ban.sh and run phase1a_rbf_ban_check on the
# local md5/sha256. A Phase 1a glass-FAIL / thrash hash prints BAN_HIT=<prefix>
# and exits 2. Soft-skip ≠ PASS — do not treat a ban as deploy success.
#
# Env:
#   MISTER_HOST   default 192.168.1.183
#   MISTER_PASS   default 1
#   DEPLOY_LOAD   none | menu | core
#                 none (default) — copy only; leave running core alone (safest)
#                 menu           — load Menu, wait, then load Plex (safer switch)
#                 core           — load Plex only (use when already on Menu)
#   DEPLOY_WAIT_S settle after load_core (default 5)
#   DEPLOY_RECOVER reboot | none  (default reboot)
#                 What to do when Main is WEDGED (accepts /dev/MiSTer_cmd writes and
#                 silently drops them). A wedged Main cannot load any core, so the only
#                 recovery is a soft reboot. MiSTer.ini is left untouched; after the
#                 reboot the core is loaded normally and re-verified.
#   DEPLOY_REBOOT_WAIT_S seconds to wait for the device to come back (default 150)
#   DEPLOY_START_DAEMON  1 (default) | 0
#                 After Plex enumerates, start misterplexd if it is not running.
#                 Pattern=None cores scan black until ARM paints + doorbell.
#                 Soft-stop around load_core is still required (mid-SPI + FPGA
#                 reload lockups). "Daemon first" means: presenter armed / back
#                 the instant CORENAME=Plex — not SPI into Menu.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
DEPLOY_LOAD="${DEPLOY_LOAD:-none}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"
DEPLOY_RECOVER="${DEPLOY_RECOVER:-reboot}"
DEPLOY_REBOOT_WAIT_S="${DEPLOY_REBOOT_WAIT_S:-150}"
DEPLOY_START_DAEMON="${DEPLOY_START_DAEMON:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Whole-pair dispatch: never fall through to the historical recovery path.
if [[ "${1:-}" == "--prebuilt-candidate" ]]; then
  shift
  exec python3 "$ROOT/scripts/deploy_candidate_pair.py" "$@"
fi
if [[ "${1:-}" == --* && "${1:-}" != "--help" ]]; then
  echo "Unknown deployment option; candidate deployment requires --prebuilt-candidate." >&2
  exit 2
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Safe Plex.rbf deploy to MiSTer (copy / menu bounce / core reload).

Usage:
  ./scripts/deploy_plex_core.sh [path/to/Plex.rbf]
  ./scripts/deploy_plex_core.sh --help
  ./scripts/deploy_plex_core.sh --prebuilt-candidate --manifest FILE --mode copy-only|menu

Env:
  MISTER_HOST   default 192.168.1.183
  MISTER_PASS   default 1
  DEPLOY_LOAD   none | menu | core   (default none = copy only)

Ban:
  After LOCAL_MD5, a Phase 1a glass-FAIL / historical thrash hash is refused
  before scp/menu. Prints BAN_HIT=<md5-or-sha256-prefix8> and exits 2.
  Soft-skip ≠ PASS. Does not skip-as-success.
EOF
  exit 0
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

LOCAL_MD5=$(md5sum "$RBF" | awk '{print $1}')
echo "Deploy $RBF (md5=$LOCAL_MD5)"
echo "  host=$USER@$HOST  load=$DEPLOY_LOAD  start_daemon=$DEPLOY_START_DAEMON"

# Phase 1a glass-FAIL luck-reload ban: refuse BEFORE any SSH / scp / menu.
# Soft-skip ≠ PASS. BAN_HIT is a hard abort (exit 2), not skip-as-success.
_BAN_SH="$ROOT/tests/unit/test_phase1a_rbf_ban.sh"
if [[ ! -f "$_BAN_SH" ]]; then
  echo "phase1a_rbf_ban: missing $_BAN_SH — refuse deploy (cannot prove not-banned)" >&2
  exit 1
fi
# shellcheck source=../tests/unit/test_phase1a_rbf_ban.sh
# shellcheck disable=SC1090
source "$_BAN_SH"
LOCAL_SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
  LOCAL_SHA256=$(sha256sum "$RBF" | awk '{print $1}')
  echo "  sha256=$LOCAL_SHA256"
fi
_phase1a_deploy_ban_one() {
  local hash="$1" kind="$2" out rc prefix
  [[ -z "$hash" ]] && return 0
  set +e
  out="$(phase1a_rbf_ban_check "$hash" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -eq 2 ]]; then
    prefix="$(phase1a_rbf_ban_normalize "$hash")"
    prefix="${prefix:0:8}"
    echo "BAN_HIT=${prefix}"
    echo "phase1a_rbf_ban: refuse scp/menu — ${kind} glass-FAIL / thrash (not skip-as-PASS)" >&2
    exit 2
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "phase1a_rbf_ban: ${kind} check failed rc=$rc — refuse deploy" >&2
    exit 1
  fi
}
_phase1a_deploy_ban_one "$LOCAL_MD5" "md5"
_phase1a_deploy_ban_one "$LOCAL_SHA256" "sha256"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -o ServerAliveInterval=3 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

# FPGA reload only: pause SPI + companion. Copy-only leaves the presenter running
# so glass does not go black for a file replace.
WILL_RELOAD=0
case "$DEPLOY_LOAD" in
  menu|bounce|core|plex|1) WILL_RELOAD=1 ;;
esac

# --- remote prep: release SPI; soft-stop companion only if we will load_core ---
"${SSH[@]}" "bash -s" <<REMOTE
set +e
# Drop any SPI flock holders gently
if [ -f /tmp/misterplex_spi.lock ]; then
  # processes blocking on flock — TERM only
  for p in \$(ps | grep -E '[s]et_status|[p]ush_frame' | awk '{print \$1}'); do
    kill "\$p" 2>/dev/null
  done
  sleep 0.3
  rm -f /tmp/misterplex_spi.lock
fi
if [ "$WILL_RELOAD" = "1" ]; then
  # Soft-stop misterplexd so it is not mid-SPI when FPGA reloads
  if ps | grep -v grep | grep -q '[m]isterplexd'; then
    killall misterplexd 2>/dev/null
    for i in 1 2 3 4 5 6 7 8; do
      ps | grep -v grep | grep -q '[m]isterplexd' || break
      sleep 0.25
    done
    if ps | grep -v grep | grep -q '[m]isterplexd'; then
      killall -9 misterplexd 2>/dev/null
    fi
  fi
fi
# Ensure Main is not left SIGSTOP'd from a crashed SpiExclusive
killall -CONT MiSTer 2>/dev/null
killall -CONT MiSTer_groovy 2>/dev/null
sync
REMOTE

# Presenter must be live the moment Plex enumerates. Pattern=None + no doorbell = black.
start_companion_after_plex() {
  if [ "$DEPLOY_START_DAEMON" != "1" ]; then
    echo "DEPLOY_START_DAEMON=$DEPLOY_START_DAEMON — leaving companion as-is"
    return 0
  fi
  echo "Start companion (Plex must already be CORENAME)"
  "${SSH[@]}" 'bash -s' <<'REMOTE'
set +e
if ps | grep -v grep | grep -q '[m]isterplexd'; then
  echo "misterplexd already running: $(ps | grep -v grep | grep '[m]isterplexd' | head -2)"
  exit 0
fi
if [ -x /media/fat/misterplex/bin/misterplexd_supervise.sh ]; then
  nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >/dev/null 2>&1 &
  echo "started misterplexd_supervise pid=$!"
elif [ -x /media/fat/misterplex/bin/misterplexd ]; then
  nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 \
    --conf /media/fat/misterplex/misterplex.conf \
    >>/media/fat/misterplex/misterplexd.log 2>&1 &
  echo "started misterplexd pid=$!"
else
  echo "WARN: no misterplexd on box — scanout stays black until the companion starts" >&2
  exit 0
fi
sleep 0.8
ps | grep -v grep | grep misterplexd | head -3 || true
REMOTE
}

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
    start_companion_after_plex
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
    start_companion_after_plex
    ;;
  *)
    echo "Unknown DEPLOY_LOAD=$DEPLOY_LOAD (use none|menu|core)" >&2
    exit 2
    ;;
esac

echo "Done."
