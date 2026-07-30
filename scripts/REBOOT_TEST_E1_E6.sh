#!/usr/bin/env bash
# COPY-PASTE cold-boot test — ONLY with user window. Does NOT reboot by itself
# unless EXECUTE_REBOOT=1 and USER_AUTHORIZE_REBOOT=YES.
#
# Expected AFTER hook restore, BEFORE any bootcore change:
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ID_WANT=misterplex-dev
EXPECT_MD5="${EXPECT_ARM_MD5:-a56bbc3c04863079ac0b29f81c45ceba}"

ssh_c() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST" "$@"
}

echo "=== PRE snapshot (run before reboot) ==="
ssh_c 'echo CORENAME=$(cat /tmp/CORENAME 2>/dev/null); echo uptime=$(cut -d" " -f1 /proc/uptime); echo md5=$(md5sum /media/fat/misterplex/bin/misterplexd|awk "{print \$1}"); echo hook_md5=$(md5sum /media/fat/linux/_user-startup.sh|awk "{print \$1}"); grep -n misterplex /media/fat/linux/_user-startup.sh /media/fat/linux/user-startup.sh; echo conf_keys=$(grep -E "^(PRESENT|DECODE|STREAM|OSD_CONTROL)=" /media/fat/misterplex/misterplex.conf|tr "\n" " "); grep -cE "^PLEX_TOKEN=." /media/fat/misterplex/misterplex.conf | xargs -I{} echo token_key_set={}; grep -n bootcore /media/fat/MiSTer.ini | head -5'

if [[ "${EXECUTE_REBOOT:-0}" == "1" && "${USER_AUTHORIZE_REBOOT:-NO}" == "YES" ]]; then
  echo "=== REBOOT authorised — sync && reboot ==="
  ssh_c 'sync; reboot' || true
  echo "waiting 90s for host..."
  sleep 90
  for i in $(seq 1 30); do
    if ssh_c 'true' 2>/dev/null; then echo "ssh_up at try $i"; break; fi
    sleep 3
  done
else
  echo "=== DRY: set USER_AUTHORIZE_REBOOT=YES EXECUTE_REBOOT=1 to reboot ==="
  echo "After manual reboot +90s, re-run with POST_ONLY=1"
fi

if [[ "${POST_ONLY:-0}" == "1" || ( "${EXECUTE_REBOOT:-0}" == "1" && "${USER_AUTHORIZE_REBOOT:-NO}" == "YES" ) ]]; then
  echo "=== POST (+net up) ==="
  ssh_c 'echo E1_ps=$(ps w|grep "[m]isterplexd"||echo EMPTY); echo E2_resources=$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null|head -c 200||echo FAIL); echo E3_CORENAME=$(cat /tmp/CORENAME 2>/dev/null); echo E4_conf=$(grep -E "^(PRESENT|DECODE|STREAM|OSD_CONTROL)=" /media/fat/misterplex/misterplex.conf|tr "\n" " "); echo E4_token_key=$(grep -cE "^PLEX_TOKEN=." /media/fat/misterplex/misterplex.conf); echo E5_md5=$(md5sum /media/fat/misterplex/bin/misterplexd|awk "{print \$1}"); echo hook=$(grep misterplex /media/fat/linux/_user-startup.sh)'
  cat <<'EXPECT'

EXPECTED (hook restored, bootcore OFF):
  E1 ps misterplexd     → RUNNING with --id misterplex-dev --port 3005 --conf .../misterplex.conf
  E2 /resources         → machineIdentifier="misterplex-dev"
  E3 CORENAME           → MENU (or non-Plex) until user loads Plex.rbf
  E4 conf keys          → PRESENT=fpga DECODE=320x240 STREAM=0 OSD_CONTROL=1; token key still set
  E5 bin md5            → a56bbc3c… (or later authorised ship)
  E6 after MANUAL load Plex.rbf from OSD:
       presents can advance; cast usable
       (if daemon started on MENU, may need present re-init — note in results)

FAIL if:
  - no daemon (hook still broken)
  - --id misterplex-183 or other non-canonical
  - conf product keys missing / token key gone
  - bootcore unexpectedly enabled
EXPECT
fi
