#!/usr/bin/env bash
# power_cycle_pair_rehearsal.sh — PARENT runbook generator + host-side gates.
# Does NOT ssh/deploy (agents must not touch the device). Prints exact commands.
#
# Modes:
#   plan              print full power-cycle procedure (default)
#   host-preflight    run host-only gates that must be green before reboot
#   print-on-device    emit the detached on-device script path + launch lines
#
# Capture honesty: HDMI is host-side only via scripts/hdmi_capture_idle.sh
# (warm-up baked in). NEVER ffmpeg -frames:v 1 alone (cold grabber 7,7,7).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PAIR_ID="${PAIR_ID:-ddr-c5382bee}"
EXPECT_DAEMON_PREFIX="${EXPECT_DAEMON_PREFIX:-edc3a46b}"
ONDEV="$ROOT/scripts/on_device_pair_boot_check.sh"

cmd="${1:-plan}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

print_plan() {
  cat <<EOF
=== POWER-CYCLE PAIR REHEARSAL (daily driver) pair_id=$PAIR_ID ===
Host=$HOST  time=$(ts)

WHY: every live measurement that is not cold-boot proven can be a hand-configured
session destroyed by the next power cycle. Atomic pair = core + daemon + conf +
REAL boot hook (from S99user USER_SCRIPT=). Decoy _user-startup.sh is NEVER executed.

CONF is USER-OWNED: backup byte-for-byte before any promote/rollback; restore
with PAIR_CONF_RESTORE_FILE=... — never silently rewrite DECODE/IDLE/etc.

------------------------------------------------
0) HOST preflight (no reboot)
------------------------------------------------
  cd $ROOT
  scripts/power_cycle_pair_rehearsal.sh host-preflight
  echo "true rc=\$?"
  # expect true rc=0

------------------------------------------------
1) ON-DEVICE: install check script + take undo snapshots (SSH may drop — detach)
------------------------------------------------
  scp $ONDEV ${USER}@${HOST}:/media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh
  ssh ${USER}@${HOST} 'chmod +x /media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh'

  # Detached snapshot+hook-rehearse (survives SSH rc=255 mid-flight):
  ssh ${USER}@${HOST} 'cat > /media/fat/misterplex_v2/bin/pre_reboot_snapshot.sh << "SNAP"
#!/bin/sh
set -eu
R=/media/fat/misterplex_v2
TS=\$(date -u +%Y%m%dT%H%M%SZ)
OUT=\$R/pre-reboot-\$TS
mkdir -p "\$OUT"
# resolve REAL hook
INIT=/etc/init.d/S99user
line=\$(grep -E "^[[:space:]]*USER_SCRIPT=" "\$INIT" | tail -1)
val=\${line#USER_SCRIPT=}
val=\$(printf "%s" "\$val" | sed "s/^[[:space:]]*//;s/[[:space:]]*\$//;s/^\\"//;s/\\"\$//")
HOOK=\$val
echo HOOK=\$HOOK | tee "\$OUT/meta.txt"
cp -a "\$HOOK" "\$OUT/user-startup.sh.bak" 2>/dev/null || true
cp -a /media/fat/linux/_user-startup.sh "\$OUT/_user-startup.sh.bak" 2>/dev/null || true
cp -a \$R/misterplex.conf "\$OUT/misterplex.conf.bak" 2>/dev/null || true
cp -a \$R/bin/misterplexd "\$OUT/misterplexd.bak" 2>/dev/null || true
md5sum /media/fat/_Utility/Plex.rbf /media/fat/_Utility/Plex_v2.rbf \
  \$R/bin/misterplexd \$R/misterplex.conf "\$HOOK" > "\$OUT/md5.txt" 2>/dev/null || true
echo SNAP_OK dir=\$OUT
# hook rehearse without reboot
EXPECT_DAEMON_PREFIX=$EXPECT_DAEMON_PREFIX \
  \$R/bin/on_device_pair_boot_check.sh rehearse-hook \
  > \$R/boot-check-rehearse.txt 2>&1 || true
echo REHEARSE_RC=\$(cat \$R/boot-check-report.txt.rc 2>/dev/null || echo missing)
SNAP
chmod +x /media/fat/misterplex_v2/bin/pre_reboot_snapshot.sh
nohup /media/fat/misterplex_v2/bin/pre_reboot_snapshot.sh \
  >/media/fat/misterplex_v2/pre-reboot.nohup.out 2>&1 &
echo DETACHED_PID=\$!
'
  # Wait, then fetch results (retry on rc=255):
  ssh ${USER}@${HOST} 'cat /media/fat/misterplex_v2/boot-check-report.txt; echo; cat /media/fat/misterplex_v2/boot-check-report.txt.rc; echo true rc=\$(cat /media/fat/misterplex_v2/boot-check-report.txt.rc)'
  # PASS rehearse: true rc=0, n_daemon=1, live md5 ${EXPECT_DAEMON_PREFIX}…, REAL hook v2 only
  # FAIL → DO NOT REBOOT. Fix hook. Atomic restore if needed.

------------------------------------------------
2) HOST visual (warm-up baked in — never -frames:v 1 alone)
------------------------------------------------
  scripts/hdmi_capture_idle.sh $ROOT/build/pair-visual/pre-reboot-idle.png
  echo "true rc=\$?"
  PAIR_IDLE_PNG=$ROOT/build/pair-visual/pre-reboot-idle.png \\
    PAIR_VISUAL_NO_RECAPTURE=1 \\
    scripts/pair_visual_gate.sh idle
  echo "true rc=\$?"
  # expect OK class=plex_idle_chevron  true rc=0
  # ABORT on grabber_not_ready_exhausted / not_plex_idle_chevron / MENU

  # Full gate (motion required when grabber present):
  PROMOTE_MOTION_CAPTURE_DIR=/path/to/trek24-burst \\
    scripts/promotion_gate_check.sh verify-live
  echo "true rc=\$?"
  # expect PROMOTE_GATES_OK true rc=0 including OK PLXS_SEQ advanced

------------------------------------------------
3) REAL cold boot (parent)
------------------------------------------------
  # reboot device; wait for network
  ssh ${USER}@${HOST} true; echo "true rc=\$?"   # must be 0

  # Detached post-boot check (SSH-drop safe):
  ssh ${USER}@${HOST} 'nohup /media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh postboot \
    >/media/fat/misterplex_v2/boot-check.nohup.out 2>&1 &'
  sleep 8
  ssh ${USER}@${HOST} 'cat /media/fat/misterplex_v2/boot-check-report.txt; echo true rc=\$(cat /media/fat/misterplex_v2/boot-check-report.txt.rc)'

  PASS postboot:
    n_daemon=1
    live_md5 prefix ${EXPECT_DAEMON_PREFIX}
    live_conf under /media/fat/misterplex_v2 (from cmdline --conf)
    REAL hook single v2 supervise; decoy inert
    http 200; PLXS_MAGIC OK if devmem present
    product-core-disk note is ON-DISK only

  Then host visual again:
    scripts/hdmi_capture_idle.sh $ROOT/build/pair-visual/post-reboot-idle.png
    PAIR_IDLE_PNG=... scripts/pair_visual_gate.sh idle; echo "true rc=\$?"

------------------------------------------------
4) IMMEDIATE ROLLBACK if FAIL (SSH alive)
------------------------------------------------
  # stop
  ssh ${USER}@${HOST} 'for d in /proc/[0-9]*; do x=\$(readlink -f \$d/exe 2>/dev/null)||continue; [ "\$(basename \$x)" = misterplexd ] && kill \${d#/proc/}; done; sleep 1'

  # restore REAL hook + conf from snapshot (byte-faithful)
  # SNAPDIR=/media/fat/misterplex_v2/pre-reboot-TIMESTAMP
  ssh ${USER}@${HOST} 'SNAPDIR=\$(ls -d /media/fat/misterplex_v2/pre-reboot-* | tail -1)
    INIT=/etc/init.d/S99user
    line=\$(grep -E "^[[:space:]]*USER_SCRIPT=" \$INIT | tail -1)
    val=\${line#USER_SCRIPT=}; val=\$(printf %s "\$val" | sed "s/[\\"'"'"']//g")
    cp -a \$SNAPDIR/user-startup.sh.bak "\$val"
    cp -a \$SNAPDIR/misterplex.conf.bak /media/fat/misterplex_v2/misterplex.conf
    # inert decoy
    : > /media/fat/linux/_user-startup.sh
    sync'

  # Atomic pair from lab host (core+daemon+conf+boot):
  PAIR_ID=$PAIR_ID \\
    PAIR_CONF_RESTORE_FILE=\$PWD/build/conf-restore/misterplex.conf.bak \\
    PAIR_IDLE_PNG=$ROOT/build/pair-visual/pre-reboot-idle.png \\
    scripts/rollback_v2.sh restore
  echo "true rc=\$?"

  # SPI undo alternative:
  # PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \\
  #   PAIR_IDLE_PNG=... scripts/rollback_v2.sh restore

  NEVER scripts/restore_misterplexd_prev.sh (disabled rc=10; half-restore black screen)

------------------------------------------------
5) If SSH dead
------------------------------------------------
  Serial console or physical SD:
    - restore user-startup.sh from pre-reboot bak (path from S99user)
    - ensure Plex_v2.rbf intact; menu-load it if needed
    - conf bak under misterplex_v2/pre-reboot-*/misterplex.conf.bak

WHAT product-core-disk md5 PROVES / DOES NOT PROVE:
  PROVES: bytes of /media/fat/_Utility/Plex.rbf on the filesystem
  DOES NOT PROVE: FPGA is executing that bitstream (MENU can still be loaded)
  EXECUTION PROOF: PLXS magic 0x504C5853 at 0x300FF100 + advancing mbox_seq
                   + positive idle chevron + motion (host gate)

true rc=0
EOF
}

host_preflight() {
  local rc=0
  echo "=== host-preflight pair gates (no device) ==="
  set +e
  PAIR_ID="$PAIR_ID" "$ROOT/scripts/rollback_v2.sh" plan >/dev/null
  echo "rollback plan true rc=$?"
  set -e
  if [ ! -x "$ONDEV" ] && [ ! -f "$ONDEV" ]; then
    echo "FAIL missing $ONDEV"
    rc=3
  else
    bash -n "$ONDEV"
    echo "on_device_pair_boot_check bash -n true rc=$?"
    echo "OK on-device script present"
  fi
  bash -n "$ROOT/scripts/rollback_v2.sh"
  bash -n "$ROOT/scripts/promotion_gate_check.sh"
  bash -n "$ROOT/scripts/hdmi_capture_idle.sh"
  echo "OK host scripts bash -n"
  # restore_misterplexd_prev must refuse
  set +e
  out=$("$ROOT/scripts/restore_misterplexd_prev.sh" 2>&1)
  r=$?
  set -e
  echo "restore_misterplexd_prev true rc=$r"
  [ "$r" -eq 10 ] || { echo "FAIL half-restore not disabled"; rc=3; }
  echo "$out" | grep -qi 'HALF_RESTORE\|ATOMIC' && echo "OK half-restore refused" || true
  # conf policy: render must preserve foreign keys
  local tmp="$ROOT/build/power-cycle-conf-test.$$"
  mkdir -p "$(dirname "$tmp")"
  printf 'DECODE=624x480\nIDLE_SCREEN=1\nAUDIO_CLOCK_PPM=12\n' >"$tmp.in"
  # shellcheck source=pair_ship_policy.sh
  source "$ROOT/scripts/pair_ship_policy.sh"
  pair_policy_render_conf ddr "$tmp.in" >"$tmp.out"
  grep -q 'DECODE=624x480' "$tmp.out" || { echo "FAIL render dropped user DECODE"; rc=3; }
  grep -q 'IDLE_SCREEN=1' "$tmp.out" || { echo "FAIL render dropped IDLE_SCREEN"; rc=3; }
  grep -q 'DDR_YUV_FORCE_SCALE=1' "$tmp.out" || { echo "FAIL render missing DDR key"; rc=3; }
  echo "OK conf-merge preserves user keys"
  rm -f "$tmp.in" "$tmp.out"
  echo "true rc=$rc"
  return "$rc"
}

case "$cmd" in
  plan|dry-run) print_plan ;;
  host-preflight) host_preflight ;;
  print-on-device)
    echo "ON_DEVICE_SCRIPT=$ONDEV"
    echo "true rc=0"
    ;;
  *)
    echo "usage: $0 {plan|host-preflight|print-on-device}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
