#!/usr/bin/env bash
# v9b aligned capture — P and B from ONE wall window; tid birth/death sampling.
# Run UNDER mister_soft_bounce claim. Never kill -9. Restore PROFILE=0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
ART="$ROOT/build/arm-deploy-v9b-aligned"
EXPECT_MD5="e9c5e5a1f765dfa9ed9bb330f3f40582"
ID=misterplex-dev
SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12
     -o ServerAliveInterval=3 -o ServerAliveCountMax=8 "$USER@$HOST")

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$ART/host.log"; }

mkdir -p "$ART"
: >"$ART/host.log"

log "=== V9B ALIGNED CAPTURE BEGIN ==="

# --- identity / refuse wrong binary ---
log "identity"
"${SSH[@]}" 'set -e
echo CORENAME=$(cat /tmp/CORENAME)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo rbf=$(md5sum /media/fat/_Utility/Plex.rbf | awk "{print \$1}")
ps w | grep -E "[m]isterplexd|[s]upervise" || true
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" /media/fat/misterplex/misterplex.conf
python -c "import os; print(\"HZ\", os.sysconf(\"SC_CLK_TCK\"))"
' | tee "$ART/identity.txt"
live=$("${SSH[@]}" 'md5sum /media/fat/misterplex/bin/misterplexd' | awk '/^[0-9a-f]{32}/{print $1; exit}')
log "live_md5=$live expect=$EXPECT_MD5"
if [[ "$live" != "$EXPECT_MD5" ]]; then
  log "REFUSE: live binary is not v9 freeze"
  exit 2
fi

# Push remote helpers (busybox-friendly)
log "push_remote_helpers"
"${SSH[@]}" 'cat > /media/fat/misterplex/v9b_tid_sample.sh' <<'EOS'
#!/bin/sh
# Sample all tids of mpid every ~50ms; log wall_s tid j=ut+st
# Args: mpid outfile duration_s
set -eu
mpid=$1
out=$2
dur=$3
: >"$out"
t0=$(awk '{print $1}' /proc/uptime)
while true; do
  now=$(awk '{print $1}' /proc/uptime)
  # elapsed
  el=$(awk -v a="$t0" -v b="$now" 'BEGIN{printf "%.3f", b-a}')
  done=$(awk -v e="$el" -v d="$dur" 'BEGIN{exit !(e>=d)}')
  # always sample once more at end
  if [ -d "/proc/$mpid/task" ]; then
    for tdir in /proc/$mpid/task/[1-9]*; do
      [ -d "$tdir" ] || continue
      tid=${tdir##*/}
      # stat: after comm) fields... utime=14 stime=15 relative to full file is hard;
      # parse: find last ) then skip to utime stime
      if [ -r "$tdir/stat" ]; then
        line=$(cat "$tdir/stat" 2>/dev/null) || continue
        rest=${line#*) }
        # rest: state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime
        set -- $rest
        # $1=state $2=ppid ... $12=utime $13=stime (1-based after state)
        ut=$12; st=$13
        j=$((ut + st))
        echo "$el $tid $j" >>"$out"
      fi
    done
  fi
  awk -v e="$el" -v d="$dur" 'BEGIN{exit !(e>=d)}' && break
  # ~50ms
  sleep 0.05
done
EOS
"${SSH[@]}" 'cat > /media/fat/misterplex/v9b_play.sh' <<'EOS'
#!/bin/sh
# playMedia key=/library/metadata/11 — token never printed
set -eu
CONF=/media/fat/misterplex/misterplex.conf
TOKEN=$(grep -E '^[[:space:]]*PLEX_TOKEN=' "$CONF" | head -1 | sed 's/^[^=]*=//' | tr -d '\r')
BASE=$(grep -E '^[[:space:]]*PLEX_BASE=' "$CONF" | head -1 | sed 's/^[^=]*=//' | tr -d '\r')
BASE=${BASE:-http://192.168.1.41:32400}
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
if wget -q -O /dev/null --timeout=3 "${BASE}/identity" 2>/dev/null; then
  echo PMS_REACHABLE=1
else
  echo PMS_REACHABLE=0
fi
ENC_KEY='%2Flibrary%2Fmetadata%2F11'
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=${1:-v9b}&machineIdentifier=misterplex-dev&address=${ADDR}&port=${PORT}&protocol=http"
[ -n "$TOKEN" ] && URL="${URL}&X-Plex-Token=${TOKEN}"
wget -q -O /dev/null "$URL" 2>/dev/null && echo play_rc=0 || echo play_rc=$?
EOS
"${SSH[@]}" 'chmod +x /media/fat/misterplex/v9b_tid_sample.sh /media/fat/misterplex/v9b_play.sh'

set_profile() {
  local val=$1
  log "set_PROFILE=$val"
  "${SSH[@]}" "set -e
CONF=/media/fat/misterplex/misterplex.conf
ts=\$(date -u +%Y%m%dT%H%M%SZ)
cp -a \"\$CONF\" \"/media/fat/misterplex/backup/misterplex.conf.v9b-\${ts}\"
if grep -qE '^[[:space:]]*PRESENT_PROFILE=' \"\$CONF\"; then
  sed -i 's/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=${val}/' \"\$CONF\"
else
  printf '\nPRESENT_PROFILE=${val}\n' >>\"\$CONF\"
fi
grep -E '^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=' \"\$CONF\"
# TERM daemon only; supervise respawns
for p in \$(pidof misterplexd 2>/dev/null); do kill \"\$p\" 2>/dev/null || true; done
sleep 2.8
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  grep -q \"PRESENT_PROFILE=${val}\" /media/fat/misterplex/misterplexd.log 2>/dev/null && break
  sleep 0.4
done
grep 'PRESENT_PROFILE=' /media/fat/misterplex/misterplexd.log | tail -3
ps w | grep -E '[m]isterplexd' | grep -v bash || true
wget -q -O /dev/null http://127.0.0.1:3005/resources && echo PORT_UP=1 || echo PORT_UP=0
"
}

# One aligned window at given profile. Writes remote /media/fat/misterplex/v9b_win_* then we pull.
run_aligned_window() {
  local tag=$1   # p1 or p0
  local profile=$2
  local dur=${3:-50}
  log "WINDOW tag=$tag PROFILE=$profile dur=${dur}s"
  set_profile "$profile"

  "${SSH[@]}" "set -e
TAG=$tag
DUR=$dur
LOG=/media/fat/misterplex/misterplexd.log
OUTDIR=/media/fat/misterplex
# stop any prior play
wget -q -O /dev/null 'http://127.0.0.1:3005/player/playback/stop?commandID=v9bprestop' 2>/dev/null || true
sleep 0.4
# clear log for window-bounded profile lines
: >\"\$LOG\"
# start play
/media/fat/misterplex/v9b_play.sh \"v9b-\${TAG}\" | tee \"\$OUTDIR/v9b_\${TAG}_play.txt\"
# settle so first frames flow
sleep 3
mpid=\$(pidof misterplexd | awk '{print \$1}')
fpid=\$(pidof ffmpeg | awk '{print \$1}')
echo \"mpid=\$mpid fpid=\${fpid:-none}\" | tee \"\$OUTDIR/v9b_\${TAG}_pids_start.txt\"
[ -n \"\$mpid\" ] || { echo NO_MPID; exit 1; }
HZ=\$(python -c 'import os; print(os.sysconf(\"SC_CLK_TCK\"))')
echo \"HZ=\$HZ\" 
read_j() { awk '{print \$14+\$15}' /proc/\$1/stat; }
read_cpu_all() { awk '/^cpu /{print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9+\$10+\$11; exit}' /proc/stat; }
read_up() { awk '{print \$1}' /proc/uptime; }
# T0
t0_up=\$(read_up)
t0_mj=\$(read_j \"\$mpid\")
t0_fj=0
[ -n \"\$fpid\" ] && [ -r /proc/\$fpid/stat ] && t0_fj=\$(read_j \"\$fpid\")
t0_cpu=\$(read_cpu_all)
echo \"T0 up=\$t0_up mj=\$t0_mj fj=\$t0_fj cpu_all=\$t0_cpu mpid=\$mpid fpid=\${fpid:-none}\" | tee \"\$OUTDIR/v9b_\${TAG}_T0.txt\"
# start tid sampler in background for DUR seconds
/media/fat/misterplex/v9b_tid_sample.sh \"\$mpid\" \"\$OUTDIR/v9b_\${TAG}_tid_samples.txt\" \"\$DUR\" &
samp=\$!
# wait wall duration
sleep \"\$DUR\"
# T1 — same mpid preferred
mpid_end=\$(pidof misterplexd | awk '{print \$1}')
fpid_end=\$(pidof ffmpeg | awk '{print \$1}')
t1_up=\$(read_up)
t1_mj=\$(read_j \"\$mpid_end\")
t1_fj=0
[ -n \"\$fpid_end\" ] && [ -r /proc/\$fpid_end/stat ] && t1_fj=\$(read_j \"\$fpid_end\")
t1_cpu=\$(read_cpu_all)
echo \"T1 up=\$t1_up mj=\$t1_mj fj=\$t1_fj cpu_all=\$t1_cpu mpid_end=\$mpid_end fpid_end=\${fpid_end:-none}\" | tee \"\$OUTDIR/v9b_\${TAG}_T1.txt\"
# wait sampler
wait \"\$samp\" 2>/dev/null || true
# marker end of window in log
echo \"V9B_WINDOW_END tag=\$TAG\" >>\"\$LOG\"
# copy profile + thread_cpu lines
grep -E 'present_profile|thread_cpu|playMedia ACK|testsrc|resolve failed|promoted SPI|kick mode|PRESENT_PROFILE|V9B_WINDOW' \"\$LOG\" \
  | sed 's/X-Plex-Token=[^ &]*/X-Plex-Token=REDACTED/g' \
  > \"\$OUTDIR/v9b_\${TAG}_log_excerpt.txt\" || true
# content class
if [ -n \"\$fpid_end\" ] && [ -r /proc/\$fpid_end/cmdline ]; then
  tr '\\0' ' ' </proc/\$fpid_end/cmdline | sed 's/X-Plex-Token=[^ ]*/X-Plex-Token=REDACTED/g' | head -c 400 > \"\$OUTDIR/v9b_\${TAG}_ffmpeg_cmd.txt\"
  echo >> \"\$OUTDIR/v9b_\${TAG}_ffmpeg_cmd.txt\"
  if tr '\\0' ' ' </proc/\$fpid_end/cmdline | grep -q testsrc; then echo CONTENT=testsrc; else echo CONTENT=not_testsrc_string; fi | tee -a \"\$OUTDIR/v9b_\${TAG}_play.txt\"
fi
# stop play
wget -q -O /dev/null 'http://127.0.0.1:3005/player/playback/stop?commandID=v9bstop' 2>/dev/null || true
# raw numbers file for host scorer
{
  echo HZ=\$HZ
  echo T0_up=\$t0_up
  echo T1_up=\$t1_up
  echo T0_mj=\$t0_mj
  echo T1_mj=\$t1_mj
  echo T0_fj=\$t0_fj
  echo T1_fj=\$t1_fj
  echo T0_cpu_all=\$t0_cpu
  echo T1_cpu_all=\$t1_cpu
  echo mpid=\$mpid
  echo mpid_end=\$mpid_end
  echo fpid=\${fpid:-none}
  echo fpid_end=\${fpid_end:-none}
  echo same_mpid=\$([ \"\$mpid\" = \"\$mpid_end\" ] && echo yes || echo no)
  echo DUR_REQUESTED=\$DUR
  echo PROFILE=$profile
  echo TAG=\$TAG
} > \"\$OUTDIR/v9b_\${TAG}_raw.txt\"
echo WINDOW_DONE tag=\$TAG
"

  # pull artifacts
  for f in \
    "v9b_${tag}_raw.txt" "v9b_${tag}_T0.txt" "v9b_${tag}_T1.txt" \
    "v9b_${tag}_play.txt" "v9b_${tag}_log_excerpt.txt" \
    "v9b_${tag}_tid_samples.txt" "v9b_${tag}_ffmpeg_cmd.txt" \
    "v9b_${tag}_pids_start.txt"
  do
    "${SSH[@]}" "cat /media/fat/misterplex/$f 2>/dev/null" >"$ART/$f" || true
  done
  log "pulled tag=$tag"
}

# Score one window on host from pulled files
score_window() {
  local tag=$1
  log "score tag=$tag"
  python3 - "$ART" "$tag" <<'PY'
import re, sys, math
from pathlib import Path
art = Path(sys.argv[1]); tag = sys.argv[2]
raw = {}
for line in (art/f"v9b_{tag}_raw.txt").read_text().splitlines():
    if "=" in line:
        k,v = line.split("=",1); raw[k]=v.strip()
HZ = float(raw.get("HZ","100"))
t0 = float(raw["T0_up"]); t1 = float(raw["T1_up"])
du = t1 - t0
dm = int(raw["T1_mj"]) - int(raw["T0_mj"])
df = int(float(raw.get("T1_fj") or 0)) - int(float(raw.get("T0_fj") or 0))
dc = int(raw["T1_cpu_all"]) - int(raw["T0_cpu_all"])
# Parent formula
P = 100.0 * dm / (HZ * du) if du > 0 else float("nan")
# Hybrid-style (for cross-ref only; nproc=2 → 200)
P_hybrid = 200.0 * dm / dc if dc > 0 else float("nan")
Ff_hybrid = 200.0 * df / dc if dc > 0 else float("nan")
Cb_hybrid = P_hybrid + Ff_hybrid if dc > 0 else float("nan")
P_ff_wall = 100.0 * df / (HZ * du) if du > 0 else float("nan")

# Buckets from present_profile lines
text = (art/f"v9b_{tag}_log_excerpt.txt").read_text(errors="replace")
profs = [l for l in text.splitlines() if "media: present_profile" in l]
def grab(l, key):
    m = re.search(rf"{key}=(-?\d+)", l)
    return int(m.group(1)) if m else 0
sum_cpu_us = 0
sum_frames = 0
sum_presented = 0
detail = []
for l in profs:
    fr = grab(l, "frames"); pr = grab(l, "presented")
    # CPU buckets only
    parts = {
        "read_cpu": grab(l, "read_cpu_us_f") * fr,
        "pacing_cpu": grab(l, "pacing_wait_cpu_us_f") * fr,
        "overlay_cpu": grab(l, "overlay_cpu_us_p") * pr,
        "fb_cpu": grab(l, "fb_cpu_us_p") * pr,
        "pixel_cpu": grab(l, "pixel_cpu_us_p") * pr,
        "ddr_cpu": grab(l, "ddr_cpu_us_p") * pr,
    }
    batch = sum(parts.values())
    sum_cpu_us += batch
    sum_frames += fr
    sum_presented += pr
    detail.append((fr, pr, parts, batch))

B = 100.0 * (sum_cpu_us * 1e-6) / du if du > 0 else float("nan")
G = P - B  # uninstrumented process CPU

# Tid samples
tid_path = art/f"v9b_{tag}_tid_samples.txt"
first = {}; last = {}; n_samples_by_tid = {}
n_lines = 0
if tid_path.exists():
    for line in tid_path.read_text().splitlines():
        parts = line.split()
        if len(parts) < 3: continue
        try:
            el, tid, j = float(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        n_lines += 1
        if tid not in first:
            first[tid] = (el, j)
        last[tid] = (el, j)
        n_samples_by_tid[tid] = n_samples_by_tid.get(tid, 0) + 1

deltas = []
for tid in first:
    dJ = last[tid][1] - first[tid][1]
    life0, life1 = first[tid][0], last[tid][0]
    ephemeral = n_samples_by_tid[tid] < max(3, n_lines // (50*max(1,len(first))))  # rough
    # better ephemeral: seen span << window or few samples
    span = life1 - life0
    ephemeral = span < 0.5 * du or n_samples_by_tid[tid] < 10
    deltas.append((dJ, tid, life0, life1, n_samples_by_tid[tid], ephemeral))
deltas.sort(reverse=True)
sum_dJ = sum(d for d, *_ in deltas) or 1

out = []
out.append(f"TAG={tag}")
out.append(f"PROFILE={raw.get('PROFILE')}")
out.append(f"HZ={HZ}")
out.append(f"du_wall_s={du:.3f}")
out.append(f"dm_process_ticks={dm}")
out.append(f"df_ffmpeg_ticks={df}")
out.append(f"dc_cpu_all={dc}")
out.append(f"same_mpid={raw.get('same_mpid')}")
out.append(f"P_pct_wall=100*dm/(HZ*du)={P:.3f}")
out.append(f"P_ffmpeg_pct_wall={P_ff_wall:.3f}")
out.append(f"P_hybrid_200dm_dc={P_hybrid:.3f}")
out.append(f"Ff_hybrid={Ff_hybrid:.3f}")
out.append(f"Cb_hybrid={Cb_hybrid:.3f}")
out.append(f"n_present_profile_batches={len(profs)}")
out.append(f"sum_frames={sum_frames} sum_presented={sum_presented}")
out.append(f"sum_bucket_cpu_us={sum_cpu_us}")
out.append(f"B_pct_wall=100*sum_cpu_us_s/du={B:.3f}")
out.append(f"G_uninstrumented_process_CPU=P-B={G:.3f}")
out.append("NOTE: G is uninstrumented process CPU, NOT hidden burn / NOT 87-hole")
out.append(f"tid_sample_lines={n_lines} unique_tids={len(first)}")
out.append(f"sum_tid_dJ={sum(d for d,*_ in deltas)} process_dm={dm} tid_cover_pct={100.0*sum(d for d,*_ in deltas)/dm if dm else float('nan'):.1f}")
ephem = [x for x in deltas if x[5]]
out.append(f"ephemeral_tid_count={len(ephem)} (span<0.5*du or samples<10)")
out.append("tid_rank dJ share life0 life1 nsamp ephemeral")
for dJ, tid, a, b, ns, ep in deltas[:16]:
    out.append(f"  tid={tid} dJ={dJ} share={100.0*dJ/sum_dJ:.1f}% life={a:.2f}-{b:.2f}s n={ns} eph={int(ep)}")
# batch detail
out.append("batch_cpu_us detail:")
for fr, pr, parts, batch in detail:
    out.append(f"  fr={fr} pr={pr} batch_us={batch} {parts}")

# content
play = (art/f"v9b_{tag}_play.txt").read_text(errors="replace") if (art/f"v9b_{tag}_play.txt").exists() else ""
out.append("PLAY_SNIP:")
out.append(play[:500])

report = "\n".join(out) + "\n"
(art/f"v9b_{tag}_SCORE.txt").write_text(report)
print(report)
PY
}

# ---- PROFILE=1 aligned window (~50s ≈ 5×300-frame batches @30fps) ----
run_aligned_window p1 1 50
score_window p1

# ---- PROFILE=0 same duration for observer effect + hybrid reconcile ----
run_aligned_window p0 0 45.26
score_window p0

# ---- ensure PROFILE=0 leave + daemon up ----
log "leave_restore"
"${SSH[@]}" 'set -e
CONF=/media/fat/misterplex/misterplex.conf
if ! grep -qE "^[[:space:]]*PRESENT_PROFILE=0" "$CONF"; then
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  cp -a "$CONF" "/media/fat/misterplex/backup/misterplex.conf.v9b-leave-${ts}"
  sed -i "s/^[[:space:]]*PRESENT_PROFILE=.*/PRESENT_PROFILE=0/" "$CONF" 2>/dev/null || printf "\nPRESENT_PROFILE=0\n" >>"$CONF"
  for p in $(pidof misterplexd 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  sleep 3
fi
# wait daemon
for i in $(seq 1 70); do
  pidof misterplexd >/dev/null 2>&1 && break
  sleep 1
done
if ! pidof misterplexd >/dev/null 2>&1; then
  for p in $(pidof misterplexd_supervise.sh 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  sleep 0.5
  nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
  sleep 2
fi
echo CORENAME=$(cat /tmp/CORENAME)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk "{print \$1}")
echo rbf=$(md5sum /media/fat/_Utility/Plex.rbf | awk "{print \$1}")
echo n_d=$(pidof misterplexd | wc -w) n_s=$(pidof misterplexd_supervise.sh | wc -w)
grep -E "^(PRESENT|STREAM|DECODE|PRESENT_PROFILE)=" /media/fat/misterplex/misterplex.conf
wget -q -O - http://127.0.0.1:3005/resources 2>/dev/null | grep -o "machineIdentifier=\"[^\"]*\"" | head -1
ps w | grep -E "[m]isterplexd|[s]upervise" | grep -v bash || true
# cleanup helpers optional keep for audit
' | tee "$ART/leave.txt"

log "=== V9B ALIGNED CAPTURE END ==="
exit 0
