#!/usr/bin/env bash
# v10 device window — run UNDER mister_soft_bounce claim.
# Install freeze; gates: idle CPU, GDM hard, playback CPU, soak. PROFILE=0 leave.
# Rollback to v9 e9c5e5a1 on GDM fail. No kill -9. No RBF/conf/token/bootcore.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
FREEZE="${FREEZE:-$ROOT/build/arm-deploy-v10-freeze/misterplexd}"
EXPECT_MD5="${EXPECT_MD5:-fb9f76192a8f7d248411c2ab2b332542}"
ROLLBACK_BIN="${ROLLBACK_BIN:-$ROOT/build/arm-deploy-v9-freeze/misterplexd}"
ROLLBACK_MD5="e9c5e5a1f765dfa9ed9bb330f3f40582"
OUT="${OUT:-$ROOT/build/arm-deploy-v10-window}"
mkdir -p "$OUT"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12
     -o ServerAliveInterval=3 -o ServerAliveCountMax=4 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/host.log"; }
ssh_clean() {
  "${SSH[@]}" "$@" 2>&1 | grep -v -E 'post-quantum|store now, decrypt|vulnerable|openssh.com/pq' || true
}

log "=== v10 window begin ==="
test -f "$FREEZE" || { log "FAIL missing freeze"; exit 2; }
local_md5=$(md5sum "$FREEZE" | awk '{print $1}')
echo "$local_md5" | tee "$OUT/freeze_md5_at_transfer.txt"
if [[ "$local_md5" != "$EXPECT_MD5" ]]; then
  log "REFUSE md5 mismatch local=$local_md5 expect=$EXPECT_MD5"
  exit 3
fi
log "md5_ok $local_md5"
log "md5_ok $local_md5"

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  log "SKIP_INSTALL=1 — verify-only on live binary"
  {
    echo "=== pre-install identity (verify-only) ==="
    ssh_clean 'echo CORENAME=$(cat /tmp/CORENAME 2>/dev/null); md5sum /media/fat/misterplex/bin/misterplexd; cat /proc/uptime; ps | grep -E "[m]isterplexd" | head -10; for p in $(pidof misterplexd); do tr "\0" " " < /proc/$p/cmdline; echo; done'
  } | tee "$OUT/identity_pre.txt"
  live=$(ssh_clean 'md5sum /media/fat/misterplex/bin/misterplexd' | awk '{print $1}' | head -1 | tr -d '\r')
  if [[ "$live" != "$EXPECT_MD5" ]]; then
    log "FAIL live md5=$live expect=$EXPECT_MD5 (verify-only)"
    exit 4
  fi
  log "verify_only live_ok=$live"
  # ensure helpers on device
  "${SCP[@]}" "$OUT/idle_sample.py" "$OUT/play_cpu_sample.py" "$USER@$HOST:/media/fat/misterplex/"
  # jump to gates via label-like: set flag and skip install block
  SKIP_TO_GATES=1
fi

if [[ "${SKIP_TO_GATES:-0}" != "1" ]]; then

{
  echo "=== pre-install identity ==="
  ssh_clean 'echo CORENAME=$(cat /tmp/CORENAME 2>/dev/null); md5sum /media/fat/misterplex/bin/misterplexd; cat /proc/uptime; ps | grep -E "[m]isterplexd" | head -10'
} | tee "$OUT/identity_pre.txt"

log "scp helpers + freeze"
"${SCP[@]}" "$OUT/idle_sample.py" "$OUT/play_cpu_sample.py" \
  "$USER@$HOST:/media/fat/misterplex/"
"${SCP[@]}" "$FREEZE" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd.v10new"
remote_md5=$(ssh_clean 'md5sum /media/fat/misterplex/bin/misterplexd.v10new' | awk '{print $1}' | tr -d '\r')
log "remote_staged_md5=$remote_md5"
if [[ "$remote_md5" != "$EXPECT_MD5" ]]; then
  log "REFUSE remote md5 mismatch=$remote_md5"
  ssh_clean 'rm -f /media/fat/misterplex/bin/misterplexd.v10new' || true
  exit 3
fi

log "swap_and_restart"
ssh_clean 'set -e
BIN=/media/fat/misterplex/bin/misterplexd
NEW=/media/fat/misterplex/bin/misterplexd.v10new
LOG=/media/fat/misterplex/misterplexd.log
SUPLOG=/media/fat/misterplex/misterplexd_supervise.log
ts=$(date +%Y%m%d%H%M%S)
mkdir -p /media/fat/misterplex/backup
for p in $(pidof misterplexd_supervise.sh 2>/dev/null); do kill "$p" 2>/dev/null || true; done
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
i=0
while pidof misterplexd >/dev/null 2>&1 || pidof misterplexd_supervise.sh >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 40 ] && break
  sleep 0.25
done
if pidof misterplexd >/dev/null 2>&1; then
  echo "WARN still running after soft kill; refuse -9"; exit 9
fi
cp -f "$BIN" "/media/fat/misterplex/backup/misterplexd.before-v10.${ts}" 2>/dev/null || true
cp -f "$NEW" "$BIN"
chmod +x "$BIN"
rm -f "$NEW"
md5sum "$BIN"
: >"$LOG"
if [ -x /media/fat/misterplex/bin/misterplexd_supervise.sh ]; then
  nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>"$SUPLOG" 2>&1 &
  sleep 2
fi
if ! pidof misterplexd >/dev/null 2>&1; then
  cd /media/fat/misterplex && nohup ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 --conf /media/fat/misterplex/misterplex.conf >>"$LOG" 2>&1 &
  sleep 1
fi
echo live_md5=$(md5sum "$BIN" | awk "{print \$1}")
echo n_d=$(pidof misterplexd 2>/dev/null | wc -w)
echo n_s=$(pidof misterplexd_supervise.sh 2>/dev/null | wc -w)
ps | grep -E "[m]isterplexd" | head -8
for p in $(pidof misterplexd 2>/dev/null); do tr "\0" " " < /proc/$p/cmdline; echo; done
sleep 1
grep -E "GDM:|PRESENT_PROFILE|listening|companion|ERROR" "$LOG" | tail -20 || true
' | tee "$OUT/install.txt"

live=$(grep -E '^live_md5=' "$OUT/install.txt" | tail -1 | cut -d= -f2 | tr -d '\r')
if [[ "$live" != "$EXPECT_MD5" ]]; then
  log "FAIL live md5=$live expect=$EXPECT_MD5"
  exit 4
fi
log "install_ok live=$live"
sleep 2

do_rollback() {
  log "ROLLBACK to v9 $ROLLBACK_MD5 reason=${1:-unspecified}"
  rb=$(md5sum "$ROLLBACK_BIN" | awk '{print $1}')
  [[ "$rb" == "$ROLLBACK_MD5" ]] || { log "rollback bin md5 bad $rb"; exit 8; }
  "${SCP[@]}" "$ROLLBACK_BIN" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd.v9rb"
  ssh_clean 'set -e
    for p in $(pidof misterplexd_supervise.sh 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    sleep 1
    cp -f /media/fat/misterplex/bin/misterplexd.v9rb /media/fat/misterplex/bin/misterplexd
    chmod +x /media/fat/misterplex/bin/misterplexd
    rm -f /media/fat/misterplex/bin/misterplexd.v9rb
    md5sum /media/fat/misterplex/bin/misterplexd
    cd /media/fat/misterplex && nohup ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 --conf /media/fat/misterplex/misterplex.conf >>/media/fat/misterplex/misterplexd.log 2>&1 &
    sleep 1
    ps | grep "[m]isterplexd" | head -5
    echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
  ' | tee "$OUT/rollback.txt"
  echo "ROLLBACK_DONE reason=$1" | tee -a "$OUT/host.log"
}

fi  # end install block

# GATE 1 idle
log "GATE1 idle sample 20s"
mpid=$(ssh_clean 'pidof misterplexd' | awk '{print $1}' | tr -d '\r')
log "mpid=$mpid"
ssh_clean "python3 /media/fat/misterplex/idle_sample.py $mpid 20" | tee "$OUT/gate1_idle.txt"
idle_p=$(awk -F= '/IDLE_P_ONECPU=/{print $2}' "$OUT/gate1_idle.txt" | tail -1)
log "GATE1 IDLE_P=$idle_p"
python3 -c "p=float('${idle_p:-999}'); print('GATE1_VERDICT=%s P=%.3f band=[0,8]'%('HIT' if 0<=p<=8 else 'MISS', p))" | tee -a "$OUT/host.log"

# GATE 2 GDM HARD
log "GATE2 GDM M-SEARCH probe"
set +e
python3 - <<'PY' | tee "$OUT/gate2_gdm.txt"
import socket, sys
HOST = "192.168.1.183"
PORT = 32412
need = [
    "HTTP/1.0 200 OK",
    "Content-Type: plex/media-player",
    "Name: MiSTerPlex",
    "Port: 3005",
    "Product: MiSTerPlex",
    "Protocol: plex",
    "Resource-Identifier: misterplex-dev",
]
probes = [
    ("msearch", b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: urn:plex-media-player\r\n\r\n'),
    ("msearch2", b"M-SEARCH * HTTP/1.1\r\nST:plex\r\n\r\n"),
    ("bare_plex", b"plex\r\nName: lab-controller\r\n\r\n"),
]
ok_any = False
for name, payload in probes:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.5)
    try:
        sock.sendto(payload, (HOST, PORT))
        data, addr = sock.recvfrom(4096)
        text = data.decode("utf-8", "replace")
        missing = [k for k in need if k not in text]
        print(f"PROBE_{name}_OK from={addr} len={len(data)} missing={missing}")
        print("---REPLY_BEGIN---")
        print(text[:900])
        print("---REPLY_END---")
        if not missing:
            ok_any = True
    except Exception as e:
        print(f"PROBE_{name}_FAIL {type(e).__name__}: {e}")
    finally:
        sock.close()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(1.5)
fake = b"HTTP/1.0 200 OK\r\nContent-Type: plex/media-player\r\nName: fake\r\nResource-Identifier: evil\r\n\r\n"
try:
    sock.sendto(fake, (HOST, PORT))
    data, addr = sock.recvfrom(4096)
    print(f"OWN_REPLY_STIMULUS_GOT_RESPONSE len={len(data)}")
    print(data[:200])
except socket.timeout:
    print("OWN_REPLY_STIMULUS_TIMEOUT (good: no self-reply to HTTP/ response)")
except Exception as e:
    print(f"OWN_REPLY_STIMULUS_ERR {e}")
finally:
    sock.close()
if ok_any:
    print("GATE2_VERDICT=HIT")
    sys.exit(0)
print("GATE2_VERDICT=MISS")
sys.exit(5)
PY
g2rc=$?
set -e
echo "gate2_script true rc=$g2rc" | tee -a "$OUT/host.log"
if [[ "$g2rc" -ne 0 ]]; then
  log "GATE2 FAIL — rolling back"
  do_rollback "gdm_probe_miss"
  exit 5
fi
log "GATE2 HIT"

# GATE 3 playback
log "GATE3 playback testsrc + CPU 45.26s"
ssh_clean 'wget -q -O- http://127.0.0.1:3005/resources 2>/dev/null | head -c 400; echo
wget -q -O- "http://127.0.0.1:3005/player/playback/playMedia?path=/tmp/x&protocol=http" >/dev/null 2>&1 || true
sleep 2
grep -E "playMedia|testsrc|resolve|frames=|ERROR" /media/fat/misterplex/misterplexd.log | tail -20
' | tee "$OUT/gate3_play_start.txt"

mpid=$(ssh_clean 'pidof misterplexd' | awk '{print $1}' | tr -d '\r')
ssh_clean "python3 /media/fat/misterplex/play_cpu_sample.py $mpid 45.26" | tee "$OUT/gate3_play_cpu.txt"
ssh_clean 'wget -q -O- "http://127.0.0.1:3005/player/playback/stop" >/dev/null 2>&1 || true'

play_p=$(awk -F= '/PLAY_P_ONECPU=/{print $2}' "$OUT/gate3_play_cpu.txt" | tail -1)
log "GATE3 PLAY_P=$play_p"
python3 -c "pre=95.0; p=float('${play_p:-999}'); d=pre-p; print('GATE3_PLAY_P=%.3f drop_vs_prefix_play95=%.3f'% (p,d)); print('GATE3_VERDICT=%s'%('HIT' if d>=60 or p<=35 else 'SOFT_MISS'))" | tee -a "$OUT/host.log"

# GATE 4 soak
log "GATE4 idle soak + re-probe"
sleep 5
ssh_clean 'wget -q -O- http://127.0.0.1:3005/resources 2>/dev/null | head -c 500; echo
grep -E "GDM:|PRESENT_PROFILE|ERROR CORENAME" /media/fat/misterplex/misterplexd.log | tail -15
echo CORENAME=$(cat /tmp/CORENAME)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo n_d=$(pidof misterplexd | wc -w)
for p in $(pidof misterplexd); do tr "\0" " " < /proc/$p/cmdline; echo; done
' | tee "$OUT/gate4_soak.txt"
python3 - <<'PY' | tee -a "$OUT/gate4_soak.txt"
import socket
HOST="192.168.1.183"; PORT=32412
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); sock.settimeout(2.5)
sock.sendto(b"M-SEARCH * HTTP/1.1\r\nST:plex\r\n\r\n",(HOST,PORT))
try:
    data,addr=sock.recvfrom(4096)
    text=data.decode()
    ok=("Resource-Identifier: misterplex-dev" in text and "Content-Type: plex/media-player" in text)
    print(f"GATE4_REPROBE={'HIT' if ok else 'MISS'} len={len(data)}")
    print(text[:400])
except Exception as e:
    print("GATE4_REPROBE=MISS", e)
PY

{
  echo "=== leave identity ==="
  ssh_clean 'echo CORENAME=$(cat /tmp/CORENAME); md5sum /media/fat/misterplex/bin/misterplexd; ps | grep -E "[m]isterplexd" | head -8; grep PRESENT_PROFILE /media/fat/misterplex/misterplexd.log | tail -5; cat /proc/uptime'
} | tee "$OUT/leave.txt"

log "=== v10 window end ==="
echo "run_v10_device_window true rc=0"
exit 0
