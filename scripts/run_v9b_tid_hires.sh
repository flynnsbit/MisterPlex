#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/build/arm-deploy-v9b-aligned"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12
     -o ServerAliveInterval=3 -o ServerAliveCountMax=8 "root@$HOST")
mkdir -p "$ART"

# Push python sampler
"${SSH[@]}" 'cat > /media/fat/misterplex/v9b_tid_sample.py' << 'PY'
#!/usr/bin/env python
from __future__ import print_function
import os, sys, time
mpid, out, dur = sys.argv[1], sys.argv[2], float(sys.argv[3])
t0 = time.time()
# also wall from uptime for alignment
def uptime():
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])
u0 = uptime()
with open(out, "w") as f:
    while True:
        el = uptime() - u0
        task = "/proc/%s/task" % mpid
        if os.path.isdir(task):
            for tid in os.listdir(task):
                if not tid[0].isdigit():
                    continue
                sp = os.path.join(task, tid, "stat")
                try:
                    with open(sp) as sf:
                        line = sf.read()
                    # pid (comm) state ... utime stime
                    rp = line.rfind(")")
                    if rp < 0:
                        continue
                    fields = line[rp+2:].split()
                    # fields[0]=state ... [11]=utime [12]=stime
                    ut = int(fields[11]); st = int(fields[12])
                    f.write("%.3f %s %d\n" % (el, tid, ut+st))
                    f.flush()
                except Exception:
                    pass
        if el >= dur:
            break
        time.sleep(0.05)
print("samples_done el=%.3f" % (uptime()-u0))
PY

echo "=== leave pre ==="
"${SSH[@]}" 'echo CORE=$(cat /tmp/CORENAME); echo n_d=$(pidof misterplexd|wc -w) n_s=$(pidof misterplexd_supervise.sh|wc -w); grep PRESENT_PROFILE= /media/fat/misterplex/misterplex.conf; md5sum /media/fat/misterplex/bin/misterplexd'

# Ensure supervise + daemon
"${SSH[@]}" 'set -e
if ! pidof misterplexd_supervise.sh >/dev/null 2>&1; then
  nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
  sleep 1.5
fi
if ! pidof misterplexd >/dev/null 2>&1; then
  # wake supervise by waiting
  sleep 2
fi
if ! pidof misterplexd >/dev/null 2>&1; then
  cd /media/fat/misterplex && nohup ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 --conf /media/fat/misterplex/misterplex.conf >>/media/fat/misterplex/misterplexd.log 2>&1 &
  sleep 1
fi
echo n_d=$(pidof misterplexd|wc -w) n_s=$(pidof misterplexd_supervise.sh|wc -w)
'

# PROFILE=1 + play + sample
"${SSH[@]}" 'set -e
CONF=/media/fat/misterplex/misterplex.conf
ts=$(date -u +%Y%m%dT%H%M%SZ)
cp -a "$CONF" "/media/fat/misterplex/backup/misterplex.conf.v9b-hires-${ts}"
sed -i "s/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=1/" "$CONF"
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 3.5
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  wget -q -O /dev/null http://127.0.0.1:3005/resources 2>/dev/null && break
  sleep 0.5
done
: >/media/fat/misterplex/misterplexd.log
/media/fat/misterplex/v9b_play.sh v9b-hires | tee /media/fat/misterplex/v9b_hires_play.txt
sleep 3
mpid=$(pidof misterplexd | awk "{print \$1}")
echo mpid=$mpid
python -c "import os; print(\"HZ\", os.sysconf(\"SC_CLK_TCK\"))"
t0=$(awk "{print \$1}" /proc/uptime)
mj0=$(awk "{print \$14+\$15}" /proc/$mpid/stat)
echo T0 up=$t0 mj=$mj0
python /media/fat/misterplex/v9b_tid_sample.py "$mpid" /media/fat/misterplex/v9b_tid_hires.txt 50
t1=$(awk "{print \$1}" /proc/uptime)
mpid2=$(pidof misterplexd | awk "{print \$1}")
mj1=$(awk "{print \$14+\$15}" /proc/$mpid2/stat)
echo T1 up=$t1 mj=$mj1 mpid2=$mpid2
echo dm=$((mj1-mj0))
echo du=$(awk -v a=$t0 -v b=$t1 "BEGIN{printf \"%.3f\", b-a}")
wc -l /media/fat/misterplex/v9b_tid_hires.txt
head -3 /media/fat/misterplex/v9b_tid_hires.txt
grep -E "present_profile|thread_cpu" /media/fat/misterplex/misterplexd.log | tail -30 > /media/fat/misterplex/v9b_hires_log.txt
# restore PROFILE=0
sed -i "s/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=0/" "$CONF"
wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop?commandID=hiresstop" 2>/dev/null || true
for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 3.5
for i in $(seq 1 40); do pidof misterplexd >/dev/null 2>&1 && break; sleep 1; done
if ! pidof misterplexd >/dev/null 2>&1; then
  if ! pidof misterplexd_supervise.sh >/dev/null 2>&1; then
    nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
  fi
  sleep 5
fi
if ! pidof misterplexd >/dev/null 2>&1; then
  cd /media/fat/misterplex && nohup ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 --conf /media/fat/misterplex/misterplex.conf >>misterplexd.log 2>&1 &
  sleep 1.2
fi
echo LEAVE CORE=$(cat /tmp/CORENAME)
echo LEAVE MD5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo LEAVE n_d=$(pidof misterplexd|wc -w) n_s=$(pidof misterplexd_supervise.sh|wc -w)
grep -E "^(PRESENT|PRESENT_PROFILE|DECODE|STREAM)=" "$CONF"
wget -q -O - http://127.0.0.1:3005/resources 2>/dev/null | grep -o "machineIdentifier=\"[^\"]*\"" | head -1
'

"${SSH[@]}" 'cat /media/fat/misterplex/v9b_tid_hires.txt' > "$ART/v9b_tid_hires.txt"
"${SSH[@]}" 'cat /media/fat/misterplex/v9b_hires_log.txt' > "$ART/v9b_hires_log.txt"
"${SSH[@]}" 'cat /media/fat/misterplex/v9b_hires_play.txt' > "$ART/v9b_hires_play.txt"
wc -l "$ART/v9b_tid_hires.txt"
head -5 "$ART/v9b_tid_hires.txt"
echo "hires_done true rc=0"
