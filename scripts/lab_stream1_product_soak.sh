#!/usr/bin/env bash
# Product STREAM=1 longer soak orchestrator (G1 cast + ring sample + STREAM=0 restore).
# Plan: Memory/lab/status/STREAM1_LONGER_SOAK_PLAN.txt
# Criteria: docs/stream1-acceptance-criteria.md (H1–H4+H7)
#
# Evidence-only: prints measured lines; does not invent PASS. Exit 0 only if
# cast soak OK AND both titles had ring advances+telem_u>=2; still restores
# STREAM=0 on failure paths when CONF_EDIT=1.
#
# Env:
#   MISTER_HOST / MISTER_USER / MISTER_PASS  (defaults: 192.168.1.183 root 1)
#   SOAK_HOLD_S     default 60
#   SOAK_KEYS       default "/library/metadata/23 /library/metadata/143"
#   CONF_EDIT       if 1, set STREAM=1 pack before run and STREAM=0 after (default 1)
#   DAEMON_RESTART  if 1, stop/start misterplexd once after conf change (default 1)
#   SKIP_CAST       if 1, only ring-sample (play must be external) (default 0)
#   SAMPLE_ONLY_S   if set with SKIP_CAST=1, sample that many seconds once
#   EVIDENCE_DIR    local dir for logs (default /tmp/stream1_g1_soak)
#
# Does NOT: Quartus, load_core thrash, claim H5/H6, plant CONT (run plant first if needed).
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
HOLD_S="${SOAK_HOLD_S:-60}"
KEYS="${SOAK_KEYS:-/library/metadata/23 /library/metadata/143}"
CONF_EDIT="${CONF_EDIT:-1}"
DAEMON_RESTART="${DAEMON_RESTART:-1}"
SKIP_CAST="${SKIP_CAST:-0}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/tmp/stream1_g1_soak}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF_REMOTE="/media/fat/misterplex/misterplex.conf"
BASE="http://${HOST}:3005"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8)
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=8)

log() { printf '[stream1-g1] %s\n' "$*"; }
die() { log "FAIL: $*"; exit 1; }

mkdir -p "$EVIDENCE_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
SUMMARY="$EVIDENCE_DIR/summary_${TS}.txt"
: >"$SUMMARY"
tee_sum() { tee -a "$SUMMARY"; }

ssh_m() { "${SSH[@]}" "${USER}@${HOST}" "$@"; }

require_tools() {
  command -v sshpass >/dev/null 2>&1 || die "sshpass required"
  command -v curl >/dev/null 2>&1 || die "curl required"
  command -v python3 >/dev/null 2>&1 || die "python3 required"
}

# On-device ring sampler (magic-word safe). Written each run so device stays in sync.
write_remote_sampler() {
  local local_py="$EVIDENCE_DIR/stream1_soak_sample.py"
  cat >"$local_py" <<'PY'
#!/usr/bin/env python3
"""STREAM=1 ring sample: PLXB/PLXR/PLXE magic-checked. True numbers only."""
import mmap, os, struct, time, sys

DATA = 0x30300000
CTRL = 0x30340000
READ = 0x30340008
ERR  = 0x30340010
ST0, ST1, ST2, ST3, ST4, ST5, ST6 = (
    0x30340018, 0x30340020, 0x30340028, 0x30340030,
    0x30340038, 0x30340040, 0x30340048,
)
MAP_LEN = 262144 + 0x1000
PLXB, PLXR, PLXE = 0x504C5842, 0x504C5852, 0x504C5845

def open_ring():
    try:
        fd = os.open("/dev/mplex_ddr", os.O_RDWR | os.O_CLOEXEC)
        base = mmap.mmap(fd, 0x300000 + MAP_LEN, mmap.MAP_SHARED,
                         mmap.PROT_READ | mmap.PROT_WRITE, offset=0)
        return fd, base, 0x300000
    except OSError:
        pass
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC | os.O_CLOEXEC)
    base = mmap.mmap(fd, MAP_LEN, mmap.MAP_SHARED,
                     mmap.PROT_READ | mmap.PROT_WRITE, offset=DATA)
    return fd, base, 0

def rd64(mm, off):
    return struct.unpack_from("<Q", mm, off)[0]

def sample(mm, doff):
    def p(phys):
        return rd64(mm, doff + (phys - DATA))
    ctrl, read, err = p(CTRL), p(READ), p(ERR)
    st6 = p(ST6)
    return dict(
        ctrl_lo=ctrl & 0xFFFFFFFF,
        plxb_count=((ctrl >> 32) & 0x7FFFFFFF) if (ctrl & 0xFFFFFFFF) == PLXB else None,
        epoch=(ctrl >> 63) & 1 if (ctrl & 0xFFFFFFFF) == PLXB else None,
        plxr_lo=read & 0xFFFFFFFF,
        cons=(read >> 32) & 0xFFFFFFFF if (read & 0xFFFFFFFF) == PLXR else None,
        plxe_lo=err & 0xFFFFFFFF,
        telem=((err >> 32) & 0xFF) if (err & 0xFFFFFFFF) == PLXE else None,
        st6h=(st6 >> 32) & 0xFFFFFFFF,
    )

def main():
    hold = float(os.environ.get("SOAK_HOLD_S", "60"))
    label = os.environ.get("SOAK_LABEL", "title")
    fd, mm, doff = open_ring()
    try:
        telem_set = set()
        cons_vals = []
        plxb_vals = []
        timeline = []
        t0 = time.time()
        s0 = sample(mm, doff)
        print("SOAK_START label=%s hold=%.1f %s" % (label, hold, {k: (hex(v) if isinstance(v, int) else v) for k, v in s0.items()}))
        last_bin = -1
        while time.time() - t0 < hold:
            s = sample(mm, doff)
            if s["cons"] is not None:
                cons_vals.append(s["cons"])
            if s["plxb_count"] is not None:
                plxb_vals.append(s["plxb_count"])
            if s["telem"] is not None:
                telem_set.add(s["telem"])
            elapsed = int(time.time() - t0)
            bin2 = elapsed // 2
            if bin2 != last_bin:
                last_bin = bin2
                c = s["cons"] if s["cons"] is not None else -1
                p = s["plxb_count"] if s["plxb_count"] is not None else -1
                timeline.append((elapsed, c, p))
            time.sleep(0.25)
        s1 = sample(mm, doff)
        cons0 = cons_vals[0] if cons_vals else -1
        cons1 = cons_vals[-1] if cons_vals else -1
        cons_max = max(cons_vals) if cons_vals else -1
        unique_cons = sorted(set(cons_vals))
        advances = bool(cons_vals) and ((cons1 > cons0) or (cons_max > cons0))
        print("SOAK_END", {k: (hex(v) if isinstance(v, int) else v) for k, v in s1.items()})
        print("label=%s cons0=0x%x cons1=0x%x cons_max=0x%x advances=%s unique_cons_n=%d" % (
            label, cons0 & 0xffffffff, cons1 & 0xffffffff, cons_max & 0xffffffff,
            advances, len(unique_cons)))
        print("telem_u=%d" % len(telem_set))
        if unique_cons:
            print("cons_path_head", [hex(c) for c in unique_cons[:20]],
                  ("..." if len(unique_cons) > 20 else ""))
        print("TIMELINE_2s", [(t, hex(c & 0xffffffff) if c >= 0 else None,
                               hex(p & 0xffffffff) if p >= 0 else None) for t, c, p in timeline[:40]])
        try:
            with open("/media/fat/misterplex/bitstream_ring.status") as f:
                print("RING_STATUS", f.read().strip()[:800])
        except Exception as e:
            print("RING_STATUS_ERR", e)
        ok = advances and len(telem_set) >= 2
        print("VERDICT", "RING_SOAK_PASS" if ok else "RING_SOAK_FAIL")
        return 0 if ok else 1
    finally:
        mm.close()
        os.close(fd)

if __name__ == "__main__":
    sys.exit(main() or 0)
PY
  "${SCP[@]}" "$local_py" "${USER}@${HOST}:/tmp/stream1_soak_sample.py"
}

set_conf_pack() {
  local stream_val="$1"
  log "conf STREAM=$stream_val pack (CONF_EDIT=$CONF_EDIT)"
  ssh_m "set -e
    CONF=$CONF_REMOTE
    test -f \$CONF
    cp -a \$CONF \${CONF}.bak_g1_${TS} 2>/dev/null || true
    set_kv() {
      k=\$1; v=\$2
      if grep -qE \"^\${k}=\" \$CONF; then sed -i -E \"s/^\${k}=.*/\${k}=\${v}/\" \$CONF
      else echo \"\${k}=\${v}\" >> \$CONF; fi
    }
    set_kv STREAM $stream_val
    if [ \"$stream_val\" = 1 ]; then
      set_kv PRESENT both
      set_kv STREAM_SKIP_RGB off
      set_kv BITSTREAM_FEED 1
      set_kv DISPLAY_RES 480p
      set_kv CONTENT_RES 480p
    fi
    grep -E '^(STREAM|PRESENT|STREAM_SKIP|BITSTREAM|DISPLAY_RES|CONTENT_RES)=' \$CONF || true
  " | tee_sum
}

restart_daemon_once() {
  [[ "$DAEMON_RESTART" == "1" ]] || { log "DAEMON_RESTART=0 — skip"; return 0; }
  log "restart misterplexd once"
  # Prefer service scripts if present; else pkill -TERM once + start
  ssh_m '
    set +e
    if [ -x /media/fat/misterplex/misterplexd ]; then
      BIN=/media/fat/misterplex/misterplexd
    elif [ -x /media/fat/linux/misterplexd ]; then
      BIN=/media/fat/linux/misterplexd
    else
      BIN=$(command -v misterplexd)
    fi
    pkill -TERM -f "[m]isterplexd" 2>/dev/null
    sleep 1
    if [ -n "$BIN" ] && [ -x "$BIN" ]; then
      nohup "$BIN" --conf /media/fat/misterplex/misterplex.conf \
        >/tmp/misterplexd_g1soak.log 2>&1 &
      echo DAEMON_START bin=$BIN pid=$!
    else
      echo DAEMON_START_SKIP no binary found
      exit 1
    fi
    sleep 2
    curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:3005/resources | head -c 200
    echo
  ' | tee_sum
}

sample_title() {
  local key="$1"
  local rk="${key##*/}"
  local out="$EVIDENCE_DIR/ring_${rk}_${TS}.txt"
  log "ring sample key=$key hold=${HOLD_S}s → $out"
  ssh_m "SOAK_HOLD_S=${HOLD_S} SOAK_LABEL=rk${rk} python3 /tmp/stream1_soak_sample.py" \
    | tee "$out" | tee_sum
  # return ring verdict
  grep -q 'VERDICT RING_SOAK_PASS' "$out"
}

play_hold_stop() {
  local key="$1"
  local rk="${key##*/}"
  local cmd=1
  local tok plex_base
  # conf token from device for playMedia
  local conf_local
  conf_local=$(mktemp)
  "${SCP[@]}" "${USER}@${HOST}:${CONF_REMOTE}" "$conf_local" 2>/dev/null || true
  tok=$(grep -E '^PLEX_TOKEN=' "$conf_local" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)
  plex_base=$(grep -E '^PLEX_BASE=' "$conf_local" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)
  if [[ -z "$plex_base" ]]; then
    local ph
    ph=$(grep -E '^PLEX_HOST=' "$conf_local" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)
    [[ -n "$ph" ]] && plex_base="http://${ph}:32400"
  fi
  rm -f "$conf_local"

  local extra=()
  [[ -n "$tok" ]] && extra+=(--data-urlencode "token=${tok}")
  local pq=(
    --data-urlencode "containerKey=/playQueues/g1soak${rk}?own=1"
    --data-urlencode "playQueueItemID=${rk}"
    --data-urlencode "playQueueVersion=1"
    --data-urlencode "ratingKey=${rk}"
  )
  if [[ -n "$plex_base" ]]; then
    local hostport="${plex_base#*://}"
    hostport="${hostport%%/*}"
    local ph="${hostport%%:*}"
    local pp="${hostport##*:}"
    [[ "$pp" == "$ph" ]] && pp=32400
    pq+=(--data-urlencode "address=${ph}" --data-urlencode "port=${pp}" --data-urlencode "protocol=http")
  fi

  log "playMedia key=$key"
  local body
  body=$(curl -fsS --connect-timeout 5 --max-time 60 --get \
    "$BASE/player/playback/playMedia" \
    --data-urlencode "key=${key}" \
    --data-urlencode "offset=0" \
    --data-urlencode "commandID=g1-${rk}-${cmd}" \
    "${pq[@]}" "${extra[@]+"${extra[@]}"}") || die "playMedia HTTP failed $key"
  echo "$body" | grep -q Timeline || die "playMedia no Timeline $key"

  # start ring sample in background on device (hold length)
  local ring_out="$EVIDENCE_DIR/ring_${rk}_${TS}.txt"
  ssh_m "SOAK_HOLD_S=${HOLD_S} SOAK_LABEL=rk${rk} python3 /tmp/stream1_soak_sample.py" \
    >"$ring_out" 2>&1 &
  local sample_pid=$!

  log "hold ${HOLD_S}s (cast + ring sample pid=$sample_pid)"
  sleep "$HOLD_S"

  wait "$sample_pid" || true
  cat "$ring_out" | tee_sum

  cmd=$((cmd + 1))
  local poll
  poll=$(curl -fsS --connect-timeout 5 --max-time 20 \
    "$BASE/player/timeline/poll?commandID=g1-poll-${rk}-${cmd}") || true
  log "poll_end: $(echo "$poll" | tr '\n' ' ' | head -c 240)"

  cmd=$((cmd + 1))
  curl -fsS --connect-timeout 5 --max-time 20 \
    "$BASE/player/playback/stop?commandID=g1-stop-${rk}-${cmd}" >/dev/null || true
  sleep 1

  grep -q 'VERDICT RING_SOAK_PASS' "$ring_out"
}

restore_stream0() {
  [[ "$CONF_EDIT" == "1" ]] || { log "CONF_EDIT=0 — operator must restore STREAM=0"; return 0; }
  log "RESTORE STREAM=0"
  set_conf_pack 0
  restart_daemon_once || log "WARN: daemon restart after restore failed"
  ssh_m "grep -E '^STREAM=' $CONF_REMOTE" | tee_sum
}

# --- main ---
require_tools
log "ts=$TS host=$HOST hold=${HOLD_S}s keys=$KEYS evidence=$EVIDENCE_DIR"
{
  echo "STREAM1_G1_SOAK start ts=$TS host=$HOST"
  echo "keys=$KEYS HOLD_S=$HOLD_S CONF_EDIT=$CONF_EDIT"
} | tee_sum

# Preflight resources
curl -fsS --connect-timeout 5 --max-time 20 "$BASE/resources" | grep -q MiSTerPlex \
  || die "no MiSTerPlex on $BASE/resources"

trap 'log "trap: attempting STREAM=0 restore"; restore_stream0 || true' EXIT

if [[ "$CONF_EDIT" == "1" ]]; then
  set_conf_pack 1
  restart_daemon_once
  curl -fsS --connect-timeout 5 --max-time 20 "$BASE/resources" | grep -q MiSTerPlex \
    || die "resources lost after STREAM=1 restart"
fi

write_remote_sampler

ring_fail=0
cast_fail=0

if [[ "$SKIP_CAST" == "1" ]]; then
  hold_once="${SAMPLE_ONLY_S:-$HOLD_S}"
  log "SKIP_CAST=1 sample only ${hold_once}s"
  ssh_m "SOAK_HOLD_S=${hold_once} SOAK_LABEL=manual python3 /tmp/stream1_soak_sample.py" \
    | tee "$EVIDENCE_DIR/ring_manual_${TS}.txt" | tee_sum
  grep -q 'VERDICT RING_SOAK_PASS' "$EVIDENCE_DIR/ring_manual_${TS}.txt" || ring_fail=1
else
  # Prefer repo cast harness for multi-key OK accounting when available
  if [[ -x "$ROOT/tests/hw/test_soak.sh" ]]; then
    log "note: using inline play+sample (not test_soak.sh alone) so ring samples overlap holds"
  fi
  for key in $KEYS; do
    log "=== title $key ==="
    if play_hold_stop "$key"; then
      log "RING OK title=$key"
    else
      log "RING FAIL title=$key"
      ring_fail=$((ring_fail + 1))
    fi
    # best-effort stop already done; brief gap between titles
    sleep 1
  done
fi

# Daemon H-gate scrapes (true lines only; no invent)
log "scrape daemon for H1-H4+H7 markers"
ssh_m '
  for f in /tmp/misterplexd_g1soak.log /media/fat/misterplex/misterplexd*.log /tmp/misterplexd*.log; do
    [ -f "$f" ] || continue
    echo "=== LOG $f ==="
    grep -E "F3 NAL producer begin|F3 NAL producer begin failed|F3 NAL producer end failed|STREAM end f3_bytes|frames=0 with STREAM|media: frames=|ddr_status|ERROR media: DDR bitstream" "$f" | tail -n 80
  done
' 2>/dev/null | tee "$EVIDENCE_DIR/daemon_hgate_${TS}.txt" | tee_sum || true

# md5 hold
ssh_m 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null || md5sum /media/fat/Plex.rbf 2>/dev/null || true' \
  | tee_sum || true

restore_stream0
trap - EXIT

{
  echo "ring_fail_count=$ring_fail cast_fail_count=$cast_fail"
  if [[ "$ring_fail" -eq 0 && "$cast_fail" -eq 0 ]]; then
    echo "ORCH_VERDICT G1_RING_CAST_OK — parent still scores H1-H4+H7 from daemon_hgate + plan; not full product ship"
  else
    echo "ORCH_VERDICT G1_FAIL ring_fail=$ring_fail"
  fi
  echo "evidence: $EVIDENCE_DIR summary=$SUMMARY"
  echo "STREAM=0 restore attempted (CONF_EDIT=$CONF_EDIT)"
} | tee_sum

log "done summary=$SUMMARY"
[[ "$ring_fail" -eq 0 && "$cast_fail" -eq 0 ]]
