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
#   DEPLOY_SKIP_COPY 0 | 1
#                 1 — bounce/load only; never scp or replace the on-device RBF.
#                 Used by scripts/mister_soft_bounce.sh so a claim signal cannot
#                 flash a different bitstream. Requires DEPLOY_LOAD=menu|core.
#   DEPLOY_WAIT_S settle after load_core (default 5)
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
DEPLOY_SKIP_COPY="${DEPLOY_SKIP_COPY:-0}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"
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

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 -o ServerAliveInterval=3 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

LOCAL_MD5=""
RBF="${1:-}"
if [[ "$DEPLOY_SKIP_COPY" == "1" ]]; then
  case "$DEPLOY_LOAD" in
    menu|bounce|core|plex|1) ;;
    *)
      echo "DEPLOY_SKIP_COPY=1 requires DEPLOY_LOAD=menu|core (got '$DEPLOY_LOAD')" >&2
      exit 2
      ;;
  esac
  # Bounce/load only: never resolve or scp a local RBF (claim soft-bounce path).
  REMOTE_MD5=$("${SSH[@]}" 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' | awk '{print $1}' || true)
  echo "Deploy SKIP_COPY=1 (on-device md5=${REMOTE_MD5:-unknown}) — will not flash RBF"
  echo "  host=$USER@$HOST  load=$DEPLOY_LOAD"
else
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
  echo "  host=$USER@$HOST  load=$DEPLOY_LOAD"

  # Provenance binding: refuse (default) or loudly warn when RBF has no matching
  # manifest. Prevents reasoning about current RTL from a months-old bitstream.
  #   DEPLOY_PROVENANCE=require (default) — exit 8 if no/bad manifest
  #   DEPLOY_PROVENANCE=warn              — print WARN, continue (distinct text)
  #   DEPLOY_PROVENANCE=off               — skip (not a pass; logs SKIP-NOT-PASS)
  DEPLOY_PROVENANCE="${DEPLOY_PROVENANCE:-require}"
  case "$DEPLOY_PROVENANCE" in
    off|0|skip)
      echo "rbf_provenance: SKIP-NOT-PASS (DEPLOY_PROVENANCE=$DEPLOY_PROVENANCE) — not scored as deploy evidence" >&2
      ;;
    warn|require|1|on|"")
      set +e
      prov_out=$(python3 "$ROOT/scripts/rbf_provenance.py" --root "$ROOT" verify --rbf "$RBF" 2>&1)
      prov_rc=$?
      set -e
      printf '%s\n' "$prov_out"
      if [[ "$prov_rc" -eq 0 ]]; then
        echo "rbf_provenance: PASS md5=$LOCAL_MD5"
        python3 "$ROOT/scripts/rbf_provenance.py" --root "$ROOT" lookup --md5 "$LOCAL_MD5" || true
      else
        echo "rbf_provenance: FAIL true rc=$prov_rc (8=no manifest, 1=mismatch, 2=cannot determine)" >&2
        if [[ "$DEPLOY_PROVENANCE" == "warn" ]]; then
          echo "rbf_provenance: WARN continuing deploy (DEPLOY_PROVENANCE=warn) — NOT a provenance PASS" >&2
        else
          echo "REFUSED: RBF lacks binding to git commit + QIP list." >&2
          echo "  Emit: python3 scripts/rbf_provenance.py emit --rbf $RBF" >&2
          echo "  Or:   DEPLOY_PROVENANCE=warn|off (off is SKIP-NOT-PASS)" >&2
          exit 8
        fi
      fi
      ;;
    *)
      echo "Unknown DEPLOY_PROVENANCE=$DEPLOY_PROVENANCE (use require|warn|off)" >&2
      exit 2
      ;;
  esac
fi

# --- remote prep: release SPI, soft-stop companion (never -9 first) ---
# Claim soft-bounce (DEPLOY_SKIP_COPY=1) never escalates to kill -9.
ALLOW_KILL9=1
[[ "$DEPLOY_SKIP_COPY" == "1" ]] && ALLOW_KILL9=0
"${SSH[@]}" "bash -s" <<REMOTE
set +e
ALLOW_KILL9=$ALLOW_KILL9
# Drop any SPI flock holders gently
if [ -f /tmp/misterplex_spi.lock ]; then
  # processes blocking on flock — TERM only
  for p in \$(ps | grep -E '[s]et_status|[p]ush_frame' | awk '{print \$1}'); do
    kill "\$p" 2>/dev/null
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
  # only if still up — never -9 on claim soft-bounce path
  if [ "\$ALLOW_KILL9" = "1" ] && ps | grep -v grep | grep -q '[m]isterplexd'; then
    killall -9 misterplexd 2>/dev/null
  fi
fi
# Ensure Main is not left SIGSTOP'd from a crashed SpiExclusive
killall -CONT MiSTer 2>/dev/null
killall -CONT MiSTer_groovy 2>/dev/null
sync
REMOTE

if [[ "$DEPLOY_SKIP_COPY" == "1" ]]; then
  echo "DEPLOY_SKIP_COPY=1 — leaving on-device /media/fat/_Utility/Plex.rbf untouched"
else
  REMOTE_MD5=$("${SSH[@]}" 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' | awk '{print $1}' || true)
  if [[ -n "${REMOTE_MD5:-}" && -n "${LOCAL_MD5:-}" && "$REMOTE_MD5" == "$LOCAL_MD5" ]]; then
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
# Prefer rename over in-place overwrite of a core that may still be mapped.
# ".bak" is single-generation and is clobbered by the NEXT deploy, so archive the
# outgoing core content-addressed as well. Two deploys used to destroy the original
# (see 3304c50 / destroyed 00eebd5e). Ported forward after HEAD lost the ancestry.
if [ -f "$FINAL" ]; then
  OUT_MD5=\$(md5sum "$FINAL" 2>/dev/null | awk '{print \$1}')
  if [ -n "\$OUT_MD5" ]; then
    ARCHIVE="/media/fat/_Utility/Plex.\${OUT_MD5:0:8}.bak.rbf"
    if [ ! -f "\$ARCHIVE" ]; then
      cp -f "$FINAL" "\$ARCHIVE" 2>/dev/null && echo "ARCHIVED \$ARCHIVE" || echo "ARCHIVE_WARN could not archive \$OUT_MD5" >&2
    else
      echo "ARCHIVE_SKIP \$ARCHIVE already present"
    fi
  else
    echo "ARCHIVE_WARN could not md5 outgoing $FINAL" >&2
  fi
  mv -f "$FINAL" "${FINAL}.bak" 2>/dev/null || true
fi
mv -f "$STAGED" "$FINAL"
chmod 755 "$FINAL"
sync
md5sum "$FINAL"
REMOTE
  fi
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
    # rc=3: MENU never appeared (Main wedged). rc=4: MENU ok but Plex never —
    # both leave the FPGA off Plex; soft-reboot recovery is the supported path.
    if [ "$rc" = "3" ] || [ "$rc" = "4" ]; then
      if [ "$DEPLOY_RECOVER" = "reboot" ]; then
        echo "DEPLOY_RECOVER=reboot after menu-bounce rc=$rc" >&2
        recover_by_reboot
      else
        echo "DEPLOY_FAIL: menu-bounce rc=$rc; DEPLOY_RECOVER=$DEPLOY_RECOVER so no recovery attempted." >&2
        exit "$rc"
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

echo "Done."

# Triple check: resident core geometry vs daemon-adopted decode=WxH.
# Read-only. Soft-skip (77) when daemon log/core map unavailable — never treat as PASS.
# Mismatch (1) fails the deploy so a 480p conf cannot ride out with a 320x240 core.
if [[ "${DEPLOY_SKIP_GEOMETRY_GATE:-0}" != "1" ]]; then
  set +e
  "$ROOT/scripts/check_core_conf_geometry.sh"
  geo_rc=$?
  set -e
  case "$geo_rc" in
    0) echo "core_conf_geometry: PASS" ;;
    77) echo "core_conf_geometry: SKIP-NOT-PASS (rc=77) — not scored as deploy success evidence" >&2 ;;
    *)
      echo "core_conf_geometry: FAIL rc=$geo_rc — core/conf geometry inconsistent" >&2
      exit "$geo_rc"
      ;;
  esac
fi
