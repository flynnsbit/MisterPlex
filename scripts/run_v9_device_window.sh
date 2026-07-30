#!/usr/bin/env bash
# v9 device window — run UNDER mister_soft_bounce claim.
# Installs freeze binary, PROFILE=1 capture, PROFILE=0 restore, hybrid-method CPU.
# Never kill -9. Never touch RBF/bootcore/token. --id misterplex-dev only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
ART="$ROOT/build/arm-deploy-v9-window"
FREEZE="$ROOT/build/arm-deploy-v9-freeze/misterplexd"
EXPECT_MD5="e9c5e5a1f765dfa9ed9bb330f3f40582"
ROLLBACK_MD5="4cbee6ffc72beeba0d4c3641ef7299fd"
ID=misterplex-dev
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12
     -o ServerAliveInterval=3 -o ServerAliveCountMax=5 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$ART/host.log"; }

mkdir -p "$ART"
: >"$ART/host.log"

log "=== V9 WINDOW BEGIN ==="
# 1) freeze md5 at transfer
md5_local=$(md5sum "$FREEZE" | awk '{print $1}')
log "freeze_md5_local=$md5_local expect=$EXPECT_MD5"
if [[ "$md5_local" != "$EXPECT_MD5" ]]; then
  log "REFUSE: freeze md5 mismatch"
  exit 2
fi

# 2) pre identity
log "pre_identity"
"${SSH[@]}" 'set -e
echo CORENAME=$(cat /tmp/CORENAME 2>/dev/null)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo rbf=$(md5sum /media/fat/_Utility/Plex.rbf | awk "{print \$1}")
ps w | grep -E "[m]isterplexd|[s]upervise" || true
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" /media/fat/misterplex/misterplex.conf
' | tee -a "$ART/pre_identity.txt"

# 3) stage binary
log "scp_stage"
"${SCP[@]}" "$FREEZE" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd.v9new"
remote_md5=$("${SSH[@]}" 'md5sum /media/fat/misterplex/bin/misterplexd.v9new' | awk '{print $1}' | tr -d '\r')
# filter PQ banner lines
remote_md5=$(echo "$remote_md5" | awk '/^[0-9a-f]{32}$/{print; exit}')
log "freeze_md5_remote=$remote_md5"
if [[ "$remote_md5" != "$EXPECT_MD5" ]]; then
  log "REFUSE: remote staged md5 mismatch got=$remote_md5"
  "${SSH[@]}" 'rm -f /media/fat/misterplex/bin/misterplexd.v9new' || true
  exit 2
fi

# 4) soft stop supervise+daemon (TERM only), install, start supervise
log "install_v9_soft"
"${SSH[@]}" 'set -e
BIN=/media/fat/misterplex/bin/misterplexd
NEW=/media/fat/misterplex/bin/misterplexd.v9new
LOG=/media/fat/misterplex/misterplexd.log
SUPLOG=/media/fat/misterplex/misterplexd_supervise.log
# soft-stop: TERM supervise first so it does not respawn mid-swap
for p in $(pidof misterplexd_supervise.sh 2>/dev/null); do kill "$p" 2>/dev/null || true; done
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
for p in $(pidof ffmpeg 2>/dev/null); do kill "$p" 2>/dev/null || true; done
# wait up to ~4s
i=0
while pidof misterplexd >/dev/null 2>&1 || pidof misterplexd_supervise.sh >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 16 ] && break
  sleep 0.25
done
if pidof misterplexd >/dev/null 2>&1; then
  echo "WARN: daemon still up after TERM — leaving (no kill -9)" >&2
  exit 3
fi
# backup live then atomic install
ts=$(date -u +%Y%m%dT%H%M%SZ)
cp -f "$BIN" "/media/fat/misterplex/backup/misterplexd.before-v9.${ts}" 2>/dev/null || true
cp -f "$BIN" "${BIN}.prev-c2"
sync "$NEW" 2>/dev/null || sync || true
mv -f "$NEW" "$BIN"
chmod +x "$BIN"
sync "$BIN" 2>/dev/null || sync || true
echo install_md5=$(md5sum "$BIN" | awk "{print \$1}")
# clear log for clean capture
: >"$LOG"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) V9_INSTALL md5=$(md5sum "$BIN" | awk "{print \$1}")" >>"$SUPLOG"
# start supervise
nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>"$SUPLOG" 2>&1 &
sleep 1.2
ps w | grep -E "[m]isterplexd|[s]upervise" || true
# id check
ps w | grep "[m]isterplexd " | grep -q -- "--id misterplex-dev" || { echo ID_FAIL; exit 7; }
echo ID_OK
# resources with retry
ok=0
for i in $(seq 1 15); do
  body=$(wget -q -O - http://127.0.0.1:3005/resources 2>/dev/null || true)
  echo "$body" | grep -q "misterplex-dev" && { ok=1; break; }
  sleep 0.2
done
[ "$ok" = 1 ] || { echo RESOURCES_FAIL; exit 7; }
echo RESOURCES_OK
' | tee -a "$ART/install.txt"

# 5) PROFILE=1 (backup conf first)
log "profile1_enable"
"${SSH[@]}" 'set -e
CONF=/media/fat/misterplex/misterplex.conf
ts=$(date -u +%Y%m%dT%H%M%SZ)
cp -a "$CONF" "/media/fat/misterplex/backup/misterplex.conf.before-v9-profile.${ts}"
echo conf_backup=/media/fat/misterplex/backup/misterplex.conf.before-v9-profile.${ts}
if grep -qE "^[[:space:]]*PRESENT_PROFILE=" "$CONF"; then
  sed -i "s/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=1/" "$CONF"
else
  printf "\nPRESENT_PROFILE=1\n" >>"$CONF"
fi
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" "$CONF"
# restart daemon under supervise: TERM child only; supervise respawns
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 2.5
ps w | grep -E "[m]isterplexd" || true
grep -q "PRESENT_PROFILE=1" /media/fat/misterplex/misterplexd.log && echo PROFILE_LINE_SEEN || \
  (tail -5 /media/fat/misterplex/misterplexd.log; sleep 1)
# wait for PROFILE line
for i in 1 2 3 4 5 6 7 8; do
  grep -q "PRESENT_PROFILE=1" /media/fat/misterplex/misterplexd.log && break
  sleep 0.5
done
grep "PRESENT_PROFILE=" /media/fat/misterplex/misterplexd.log | tail -3
' | tee -a "$ART/profile1_enable.txt"

# 6) playMedia key= (token stays on device; never printed)
log "play_profile1"
"${SSH[@]}" 'set -e
CONF=/media/fat/misterplex/misterplex.conf
# parse conf without echo token
TOKEN=$(grep -E "^[[:space:]]*PLEX_TOKEN=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=$(grep -E "^[[:space:]]*PLEX_BASE=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=${BASE:-http://192.168.1.41:32400}
# strip scheme for address/port
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
# PMS probe (no token in output)
if wget -q -O /dev/null --timeout=3 "${BASE}/identity" 2>/dev/null; then
  echo PMS_REACHABLE=1
else
  echo PMS_REACHABLE=0
fi
KEY="/library/metadata/11"
# URL-encode key roughly
ENC_KEY="%2Flibrary%2Fmetadata%2F11"
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=v9p1&machineIdentifier=misterplex-dev&address=${ADDR}&port=${PORT}&protocol=http"
if [ -n "$TOKEN" ]; then
  URL="${URL}&X-Plex-Token=${TOKEN}"
fi
# wget body to file; print only http-ish status via separate check
rm -f /media/fat/misterplex/v9_play_body.txt
wget -q -O /media/fat/misterplex/v9_play_body.txt "$URL" 2>/dev/null && echo play_wget_rc=0 || echo play_wget_rc=$?
# redact body: drop token-looking strings
sed "s/X-Plex-Token=[^&\"]*/X-Plex-Token=REDACTED/g; s/[A-Za-z0-9_-]\\{20,\\}/REDACTED_LONG/g" \
  /media/fat/misterplex/v9_play_body.txt 2>/dev/null | head -c 400
echo
# peek log for ACK / testsrc
sleep 2
grep -E "playMedia ACK|testsrc|resolve|PRESENT_PROFILE|FPGA frame|session end|ERROR CORENAME" /media/fat/misterplex/misterplexd.log | tail -20
' | tee -a "$ART/play_profile1.txt"

# 7) PROFILE=1 capture window ~55s — pull present_profile + thread_cpu
log "capture_profile1_55s"
"${SSH[@]}" 'set -e
# let media run
sleep 55
echo "=== present_profile lines ==="
grep "media: present_profile" /media/fat/misterplex/misterplexd.log | tail -8
echo "=== thread_cpu lines ==="
grep "media: thread_cpu" /media/fat/misterplex/misterplexd.log | tail -8
echo "=== steady media frames ==="
grep "media: frames=" /media/fat/misterplex/misterplexd.log | tail -6
echo "=== promote ==="
grep -E "promoted SPI|kick mode=doorbell" /media/fat/misterplex/misterplexd.log | tail -5
echo "=== doorbell sample from last profile ==="
grep "media: present_profile" /media/fat/misterplex/misterplexd.log | tail -1 | tr " " "\n" | grep -E "ddr_doorbell|ddr_cpu"
# port still up?
wget -q -O /dev/null http://127.0.0.1:3005/resources && echo PORT_UP=1 || echo PORT_UP=0
ps w | grep "[m]isterplexd " | head -3
' | tee -a "$ART/profile1_capture.txt"

# 8) stop playback, PROFILE=0 restore, restart
log "profile0_restore"
"${SSH[@]}" 'set -e
# stop
wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop?commandID=v9stop" 2>/dev/null || true
sleep 0.5
CONF=/media/fat/misterplex/misterplex.conf
ts=$(date -u +%Y%m%dT%H%M%SZ)
cp -a "$CONF" "/media/fat/misterplex/backup/misterplex.conf.after-v9-profile1.${ts}"
sed -i "s/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=0/" "$CONF"
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" "$CONF"
# TERM daemon; supervise respawns with new conf
: >/media/fat/misterplex/misterplexd.log
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 2.5
for i in 1 2 3 4 5 6 7 8 9 10; do
  grep -q "PRESENT_PROFILE=0" /media/fat/misterplex/misterplexd.log && break
  sleep 0.4
done
grep "PRESENT_PROFILE=" /media/fat/misterplex/misterplexd.log | tail -3
ps w | grep -E "[m]isterplexd|[s]upervise" || true
wget -q -O - http://127.0.0.1:3005/resources 2>/dev/null | grep -o "machineIdentifier=\"[^\"]*\"" | head -1
' | tee -a "$ART/profile0_restore.txt"

# 9) PROFILE=0 inert check: short play, no thread_cpu lines
log "profile0_inert_check"
"${SSH[@]}" 'set -e
CONF=/media/fat/misterplex/misterplex.conf
TOKEN=$(grep -E "^[[:space:]]*PLEX_TOKEN=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=$(grep -E "^[[:space:]]*PLEX_BASE=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=${BASE:-http://192.168.1.41:32400}
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
ENC_KEY="%2Flibrary%2Fmetadata%2F11"
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=v9p0inert&machineIdentifier=misterplex-dev&address=${ADDR}&port=${PORT}&protocol=http"
[ -n "$TOKEN" ] && URL="${URL}&X-Plex-Token=${TOKEN}"
wget -q -O /dev/null "$URL" 2>/dev/null || true
sleep 12
echo "thread_cpu_count=$(grep -c "media: thread_cpu" /media/fat/misterplex/misterplexd.log || true)"
echo "present_profile_count=$(grep -c "media: present_profile" /media/fat/misterplex/misterplexd.log || true)"
grep "media: frames=" /media/fat/misterplex/misterplexd.log | tail -3
grep -E "playMedia ACK|testsrc|resolve failed" /media/fat/misterplex/misterplexd.log | tail -10
' | tee -a "$ART/profile0_inert.txt"

# 10) hybrid-method CPU 45.26s PROFILE=0
log "cpu_jiffies_45"
"${SSH[@]}" 'set -e
# ensure playing
CONF=/media/fat/misterplex/misterplex.conf
TOKEN=$(grep -E "^[[:space:]]*PLEX_TOKEN=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=$(grep -E "^[[:space:]]*PLEX_BASE=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=${BASE:-http://192.168.1.41:32400}
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
ENC_KEY="%2Flibrary%2Fmetadata%2F11"
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=v9cpu&machineIdentifier=misterplex-dev&address=${ADDR}&port=${PORT}&protocol=http"
[ -n "$TOKEN" ] && URL="${URL}&X-Plex-Token=${TOKEN}"
wget -q -O /dev/null "$URL" 2>/dev/null || true
sleep 5
# settle then sample
mpid=$(pidof misterplexd | awk "{print \$1}")
fpid=$(pidof ffmpeg | awk "{print \$1}")
echo "nproc=$(nproc 2>/dev/null || echo 2)"
echo "mpid=$mpid fpid=${fpid:-none}"
if [ -z "$mpid" ]; then echo NO_MPID; exit 1; fi
read_j() { awk "{print \$14+\$15}" /proc/$1/stat; }
read_cpu_all() {
  # sum all cpu lines except cpu aggregate? hybrid uses cpu_all from /proc/stat first line
  awk "/^cpu /{print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9+\$10+\$11; exit}" /proc/stat
}
read_up() { awk "{print \$1}" /proc/uptime; }
t0_cpu=$(read_cpu_all)
t0_mj=$(read_j "$mpid")
t0_fj=0
[ -n "$fpid" ] && t0_fj=$(read_j "$fpid")
t0_up=$(read_up)
echo "t0 cpu_all=$t0_cpu mj=$t0_mj fj=$t0_fj up=$t0_up"
# sleep 45.26
sleep 45
sleep 0.26
mpid_end=$(pidof misterplexd | awk "{print \$1}")
fpid_end=$(pidof ffmpeg | awk "{print \$1}")
t1_cpu=$(read_cpu_all)
t1_mj=$(read_j "$mpid_end")
t1_fj=0
[ -n "$fpid_end" ] && t1_fj=$(read_j "$fpid_end")
t1_up=$(read_up)
echo "t1 cpu_all=$t1_cpu mj=$t1_mj fj=$t1_fj up=$t1_up mpid_end=$mpid_end fpid_end=${fpid_end:-none}"
echo "same_mpid=$([ "$mpid" = "$mpid_end" ] && echo yes || echo no)"
echo "same_fpid=$([ "${fpid:-}" = "${fpid_end:-}" ] && echo yes || echo no)"
dc=$((t1_cpu - t0_cpu))
dm=$((t1_mj - t0_mj))
df=$((t1_fj - t0_fj))
# du from uptime
du=$(awk -v a="$t0_up" -v b="$t1_up" "BEGIN{printf \"%.3f\", b-a}")
echo "dc=$dc dm=$dm df=$df du=$du"
# 200*dj/dc_cpu_all for nproc=2 → %onecpu
awk -v dc="$dc" -v dm="$dm" -v df="$df" "BEGIN{
  if(dc<=0){print \"BAD_DC\"; exit}
  mp=200.0*dm/dc; ff=200.0*df/dc; cb=mp+ff;
  printf \"misterplexd_pct_onecpu=%.1f\nffmpeg_pct_onecpu=%.1f\ncombined_pct_onecpu=%.1f\n\", mp, ff, cb;
}"
# content class
grep -E "playMedia ACK|testsrc|resolve failed|ffmpeg" /media/fat/misterplex/misterplexd.log | tail -15
grep "media: frames=" /media/fat/misterplex/misterplexd.log | tail -4
# ffmpeg cmdline class (no token)
if [ -n "$fpid_end" ] && [ -r /proc/$fpid_end/cmdline ]; then
  tr "\0" " " </proc/$fpid_end/cmdline | sed "s/X-Plex-Token=[^ ]*/X-Plex-Token=REDACTED/g" | head -c 300
  echo
  tr "\0" " " </proc/$fpid_end/cmdline | grep -q testsrc && echo CONTENT=testsrc || echo CONTENT=not_testsrc_string
fi
# stop
wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop?commandID=v9cpustop" 2>/dev/null || true
' | tee -a "$ART/cpu_jiffies45.txt"

# 11) gates: 409, seek+stop flat, MENU warn silent on Plex
log "gates_quick"
"${SSH[@]}" 'set -e
# wrong target → 409
code=$(wget -S -O /dev/null "http://127.0.0.1:3005/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F11&commandID=bad" \
  --header="X-Plex-Target-Client-Identifier: not-the-player" 2>&1 | awk "/HTTP\//{c=\$2} END{print c+0}")
echo wrong_target_http=$code
# seek+stop flat: play briefly, note frames, seek, stop, frames should not climb
CONF=/media/fat/misterplex/misterplex.conf
TOKEN=$(grep -E "^[[:space:]]*PLEX_TOKEN=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=$(grep -E "^[[:space:]]*PLEX_BASE=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=${BASE:-http://192.168.1.41:32400}
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
ENC_KEY="%2Flibrary%2Fmetadata%2F11"
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=v9seek&machineIdentifier=misterplex-dev&address=${ADDR}&port=${PORT}&protocol=http"
[ -n "$TOKEN" ] && URL="${URL}&X-Plex-Token=${TOKEN}"
wget -q -O /dev/null "$URL" 2>/dev/null || true
sleep 8
f1=$(grep "media: frames=" /media/fat/misterplex/misterplexd.log | tail -1 | sed -n "s/.*frames=\\([0-9]*\\).*/\\1/p")
wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/seekTo?offset=60000&commandID=v9s" 2>/dev/null || true
sleep 1
wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop?commandID=v9st" 2>/dev/null || true
sleep 2
f2=$(grep "media: frames=" /media/fat/misterplex/misterplexd.log | tail -1 | sed -n "s/.*frames=\\([0-9]*\\).*/\\1/p")
echo "frames_before_stopish=$f1 frames_after_stop=$f2"
# MENU warn: on Plex should be silent
: >/media/fat/misterplex/misterplexd.log
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 2.5
sleep 1
warn=$(grep -c "CORENAME" /media/fat/misterplex/misterplexd.log || true)
echo "warn_lines_on_plex_restart=$warn"
grep -E "CORENAME|PRESENT_PROFILE|misterplexd:" /media/fat/misterplex/misterplexd.log | head -15
echo CORENAME=$(cat /tmp/CORENAME)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo rbf=$(md5sum /media/fat/_Utility/Plex.rbf | awk "{print \$1}")
ps w | grep -E "[m]isterplexd|[s]upervise" || true
n_d=$(pidof misterplexd | wc -w); n_s=$(pidof misterplexd_supervise.sh | wc -w)
echo "n_daemon=$n_d n_supervise=$n_s"
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" /media/fat/misterplex/misterplex.conf
' | tee -a "$ART/gates_quick.txt"

# pull full profile log excerpt for hybrid offline
log "pull_logs"
"${SSH[@]}" 'grep -E "present_profile|thread_cpu|promoted SPI|kick mode|playMedia ACK|testsrc|resolve|SUPERVISE_|V9_" /media/fat/misterplex/misterplexd.log /media/fat/misterplex/misterplexd_supervise.log 2>/dev/null | sed "s/X-Plex-Token=[^ &]*/X-Plex-Token=REDACTED/g" | tail -n 200' \
  >"$ART/log_excerpt_redacted.txt" || true

log "=== V9 WINDOW END ==="
echo "artifacts=$ART"
exit 0
