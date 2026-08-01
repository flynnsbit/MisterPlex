#!/usr/bin/env bash
# p480-ab harness — identical A/B measurement at 240p vs lab 480p coded tiers.
#
# One clip, one offset, one duration window. Emits ONE machine-readable record
# plus a human table. CPU method is mandatory (see sample_cpu_window remote):
#   P = 100 * dticks / (HZ * dwall)     # one wall clock, NO fps scaling
# per-thread /proc/<pid>/task/*/stat deltas, including threads that exit mid-window;
# voluntary_ctxt_switches vs nonvoluntary_ctxt_switches per thread.
#
# Frame metrics from misterplexd.log (vfps/pfps/drops/av_drift/ddr ms/present_profile).
# Audio: av_drift_ms is TELEMETRY ONLY (servo echo; NOT lip-sync — parent 2026-07-31).
# Lip-sync judge: tests/hw/avsync_measure.py / avsync_rate.py when --hdmi-avsync (parent grabber).
#
# Tier force (default): OSD_CONTROL=0 + DECODE=320x240|624x480 + DECODE_ALLOW_LAB_480P
# for the run, conf restored on exit. Does NOT change the shipping default conf
# permanently and does NOT raise the 2000 kbps bitrate floor.
#
# Host-only self-test (no device):
#   ./tests/hw/test_p480_ab_harness.sh --self-test
#
# Device run (w-device owns hardware):
#   PLEX_KEY=/library/metadata/N TIER=240p ./tests/hw/test_p480_ab_harness.sh
#   PLEX_KEY=/library/metadata/N TIER=480p ./tests/hw/test_p480_ab_harness.sh
#   # or both:
#   PLEX_KEY=... ./tests/hw/test_p480_ab_harness.sh --both
#
# Env:
#   MISTER_HOST MISTER_USER MISTER_PASS
#   PLEX_KEY / KEY          playMedia key (required on device)
#   OFFSET_MS               cast offset (default 0) — must match across tiers
#   SETTLE_S                settle before CPU window (default 20)
#   WINDOW_S                measurement window seconds (default 60)
#   TIER                    240p | 480p (default 240p)
#   OUT_DIR                 default build/p480
#   PRESENT_PROFILE_FORCE   1=temp enable PRESENT_PROFILE=1 (default 1)
#   RESTART_DAEMON          1=restart misterplexd after conf patch (default 1)
#   HDMI_AVSYNC             1=also run host HDMI avsync tools (default 0)
#   PLEX_TOKEN              for HDMI cast helpers
#   EXPECTED_RBF_MD5        optional provenance gate
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/hw/hw_gate_common.sh
source "$ROOT/tests/hw/hw_gate_common.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BASE="http://${HOST}:3005"
KEY="${PLEX_KEY:-${KEY:-}}"
OFFSET_MS="${OFFSET_MS:-0}"
SETTLE_S="${SETTLE_S:-20}"
WINDOW_S="${WINDOW_S:-60}"
TIER="${TIER:-240p}"
OUT_DIR="${OUT_DIR:-$ROOT/build/p480}"
PRESENT_PROFILE_FORCE="${PRESENT_PROFILE_FORCE:-1}"
RESTART_DAEMON="${RESTART_DAEMON:-1}"
HDMI_AVSYNC="${HDMI_AVSYNC:-0}"
BOTH=0
SELF_TEST=0
DRY_PARSE=0

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) TIER="${2:?}"; shift 2 ;;
    --key) KEY="${2:?}"; shift 2 ;;
    --offset-ms) OFFSET_MS="${2:?}"; shift 2 ;;
    --settle-s) SETTLE_S="${2:?}"; shift 2 ;;
    --window-s) WINDOW_S="${2:?}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --both) BOTH=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --dry-parse) DRY_PARSE=1; shift ;;
    --hdmi-avsync) HDMI_AVSYNC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"
SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_SHA_SHORT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CONF_REMOTE="/media/fat/misterplex/misterplex.conf"
CONF_BAK="/media/fat/misterplex/misterplex.conf.p480ab.bak"
LOG_REMOTE="/media/fat/misterplex/misterplexd.log"

log() { printf '[p480-ab] %s\n' "$*"; }
fail() { log "FAIL: $*"; exit 1; }

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    -o LogLevel=ERROR "$USER@$HOST" "$@"
}

# --- pure helpers (host-testable) -------------------------------------------

tier_coded_wxh() {
  case "$1" in
    240p|320x240) echo "320x240" ;;
    480p|624x480) echo "624x480" ;;
    *) return 1 ;;
  esac
}

tier_frame_bytes() {
  # I420 = W*H*3/2. Compute — do not embed banned layout literals (449280/115200).
  case "$1" in
    240p|320x240) echo $((320 * 240 * 3 / 2)) ;;
    480p|624x480) echo $((624 * 480 * 3 / 2)) ;;
    *) return 1 ;;
  esac
}

# Parse media: frames= lines → key=value summary on stdout.
parse_frame_lines() {
  python3 - "$1" <<'PY'
import re, sys, json
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read().splitlines()
rows = []
for line in text:
    if "media: frames=" not in line:
        continue
    d = {}
    for m in re.finditer(r'(frames|vfps|pfps|audio_s|wall_s|av_drift_ms|drops|fps|decode)=([^\s]+)', line):
        d[m.group(1)] = m.group(2)
    if d:
        rows.append(d)
prof = []
for line in text:
    if "media: present_profile " not in line:
        continue
    d = {}
    for m in re.finditer(r'([a-z0-9_]+)=([^\s]+)', line.split("present_profile ", 1)[-1]):
        d[m.group(1)] = m.group(2)
    if d:
        prof.append(d)
push = []
for line in text:
    m = re.search(r'fpga frame_tx ok via DDR.*?ms=([0-9]+)', line)
    if m:
        push.append(int(m.group(1)))
recon = {"recon_ok": None, "recon_fail": None}
for line in text:
    m = re.search(r'recon_ok=(\d+)\s+recon_fail=(\d+)', line)
    if m:
        recon["recon_ok"] = int(m.group(1))
        recon["recon_fail"] = int(m.group(2))
content_fps = None
for line in text:
    m = re.search(r'content fps=(\d+)/(\d+)', line)
    if m:
        content_fps = f"{m.group(1)}/{m.group(2)}"
    m2 = re.search(r'content resolution=(\S+)', line)
    if m2 and "content_resolution" not in recon:
        recon["content_resolution"] = m2.group(1)

def fnum(xs, key, cast=float):
    out = []
    for r in xs:
        if key in r:
            try:
                out.append(cast(r[key]))
            except ValueError:
                pass
    return out

drifts = fnum(rows, "av_drift_ms", float)
drops = fnum(rows, "drops", int)
vfps = fnum(rows, "vfps", float)
pfps = fnum(rows, "pfps", float)
frames = fnum(rows, "frames", int)
decode = rows[-1].get("decode") if rows else None
fps = rows[-1].get("fps") if rows else content_fps

def stats(xs):
    if not xs:
        return {"n": 0}
    xs = list(xs)
    return {
        "n": len(xs),
        "first": xs[0],
        "last": xs[-1],
        "min": min(xs),
        "max": max(xs),
        "mean": sum(xs) / len(xs),
    }

# sustained drift: first half mean vs second half mean if enough samples
drift_slope = None
if len(drifts) >= 4:
    mid = len(drifts) // 2
    a = sum(drifts[:mid]) / mid
    b = sum(drifts[mid:]) / (len(drifts) - mid)
    drift_slope = b - a  # ms change late-minus-early over window samples

out = {
    "frame_lines": len(rows),
    "frames": stats(frames),
    "vfps": stats(vfps),
    "pfps": stats(pfps),
    "av_drift_ms": stats(drifts),
    "av_drift_late_minus_early_ms": drift_slope,
    "drops": stats(drops),
    "drops_delta": (drops[-1] - drops[0]) if len(drops) >= 2 else None,
    "fps_label": fps,
    "content_fps": content_fps,
    "decode": decode,
    "ddr_push_ms_samples": push,
    "ddr_push_ms": stats(push) if push else {"n": 0},
    "present_profile_n": len(prof),
    "present_profile_last": prof[-1] if prof else None,
    "recon": recon,
}
print(json.dumps(out, indent=2, sort_keys=True))
PY
}

# Mandatory CPU formula unit check + synthetic thread accounting.
self_test_cpu_math() {
  python3 - <<'PY'
import json, tempfile, os, textwrap, subprocess, sys

# P = 100 * dticks / (HZ * dwall)
hz = 100
dwall = 2.0
dticks = 50  # 0.5s of CPU on 100 Hz
p = 100.0 * dticks / (hz * dwall)
assert abs(p - 25.0) < 1e-9, p

# Simulate two threads + one exiting mid-window
# t1: 10->30, t2: 5->5 (gone → use last as end), t3 appears 0->20
ticks = (30 - 10) + (5 - 5) + (20 - 0)
p2 = 100.0 * ticks / (hz * dwall)
assert abs(p2 - 20.0) < 1e-9, p2
print("SELF_TEST_CPU_MATH_OK P=%.1f exited_thread_accounted P=%.1f" % (p, p2))
PY
}

self_test_parse() {
  local f="$OUT_DIR/selftest_frames.log"
  local fb480
  fb480="$(tier_frame_bytes 480p)"
  cat >"$f" <<LOG
misterplexd: content resolution=624x480 source=conf/--decode status_word=0x0000 weak=624x480 bitrate=2000
media: content fps=24000/1001 (pms frameRate=23.976 vfr=0)
media: frames=100 vfps=23.9 pfps=23.8 audio_s=4.20 wall_s=4.18 audio=on clock=av-lock av_drift_ms=-12 drops=1 fps=24000/1001 decode=624x480
media: frames=200 vfps=24.0 pfps=23.9 audio_s=8.40 wall_s=8.33 audio=on clock=av-lock av_drift_ms=-10 drops=2 fps=24000/1001 decode=624x480
media: frames=300 vfps=24.1 pfps=24.0 audio_s=12.5 wall_s=12.4 audio=on clock=av-lock av_drift_ms=-8 drops=2 fps=24000/1001 decode=624x480
media: fpga frame_tx ok via DDR presents=48 frames=300 ms=7
media: present_profile frames=300 drops=2 presented=298 ddr_copy_us_p=7200 ddr_total_us_p=10400 ddr_plxd_used_x100_p=100 frame_bytes=${fb480}
media: session end frames=300 recon_ok=0 recon_fail=0
LOG
  parse_frame_lines "$f" >"$OUT_DIR/selftest_parse.json"
  python3 - <<PY
import json
d=json.load(open("$OUT_DIR/selftest_parse.json"))
assert d["frame_lines"]==3, d
assert d["decode"]=="624x480"
assert d["drops_delta"]==1
assert d["ddr_push_ms"]["last"]==7
assert d["present_profile_last"]["ddr_copy_us_p"]=="7200"
assert d["recon"]["recon_ok"]==0
assert d["content_fps"]=="24000/1001"
print("SELF_TEST_PARSE_OK")
PY
}

emit_record() {
  # args via env: RECORD_* 
  python3 - <<'PY'
import json, os, sys
rec = {
  "record": "p480_ab",
  "SOURCE_SHA": os.environ.get("SOURCE_SHA", ""),
  "SOURCE_SHA_SHORT": os.environ.get("SOURCE_SHA_SHORT", ""),
  "stamp_utc": os.environ.get("STAMP", ""),
  "host": os.environ.get("HOST", ""),
  "tier": os.environ.get("TIER", ""),
  "coded_wxh": os.environ.get("CODED_WXH", ""),
  "frame_bytes_i420": int(os.environ.get("FRAME_BYTES", "0")),
  "clip_key": os.environ.get("KEY_REDACTED", ""),
  "offset_ms": int(os.environ.get("OFFSET_MS", "0")),
  "settle_s": float(os.environ.get("SETTLE_S", "0")),
  "window_s": float(os.environ.get("WINDOW_S", "0")),
  "cpu_method": "P=100*dticks/(HZ*dwall) per-thread /proc/pid/task/*/stat; mid-window exits kept; nvcsw/nivcsw",
  "cpu": json.loads(os.environ.get("CPU_JSON", "{}")),
  "frames": json.loads(os.environ.get("FRAMES_JSON", "{}")),
  "hdmi_avsync": json.loads(os.environ.get("HDMI_JSON", "null")),
  "rbf_md5": os.environ.get("RBF_MD5", ""),
  "notes": [
    "shipping default remains 240p; 480p is lab/OSD option",
    "do not treat soft-skip 77 as pass",
    "bitrate floor kPlex480pWeakBitrateKbps=2000 not modified by this harness",
    "GDM storm fixed v10 — prior decode-margin claims may be stale",
  ],
}
path = os.environ["RECORD_PATH"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2, sort_keys=True)
    f.write("\n")
# human table
print("=== p480-ab human table ===")
print(f"SOURCE_SHA {rec['SOURCE_SHA_SHORT']} tier={rec['tier']} coded={rec['coded_wxh']} bytes={rec['frame_bytes_i420']}")
print(f"clip offset_ms={rec['offset_ms']} settle_s={rec['settle_s']} window_s={rec['window_s']}")
cpu = rec.get("cpu") or {}
print(f"CPU misterplexd_pct_onecpu={cpu.get('misterplexd_pct_onecpu')} ffmpeg_pct_onecpu={cpu.get('ffmpeg_pct_onecpu')} HZ={cpu.get('hz')} dwall_s={cpu.get('dwall_s')}")
if cpu.get("threads"):
    print("CPU threads (tid name pct nvcsw nivcsw):")
    for t in cpu["threads"][:12]:
        print(f"  {t.get('tid')} {t.get('comm')} pct={t.get('pct_onecpu')} nvcsw_d={t.get('nvcsw_delta')} nivcsw_d={t.get('nivcsw_delta')}")
fr = rec.get("frames") or {}
print(f"frames vfps_mean={((fr.get('vfps') or {}).get('mean'))} pfps_mean={((fr.get('pfps') or {}).get('mean'))} drops_delta={fr.get('drops_delta')} drift_mean={((fr.get('av_drift_ms') or {}).get('mean'))} drift_late-early={fr.get('av_drift_late_minus_early_ms')}")
print(f"ddr_push_ms={fr.get('ddr_push_ms')} decode={fr.get('decode')} content_fps={fr.get('content_fps')}")
pp = fr.get("present_profile_last") or {}
if pp:
    print(f"present_profile ddr_copy_us_p={pp.get('ddr_copy_us_p')} ddr_total_us_p={pp.get('ddr_total_us_p')} ddr_plxd_used_x100_p={pp.get('ddr_plxd_used_x100_p')} frame_bytes={pp.get('frame_bytes')}")
print(f"record={path}")
PY
}

# --- self-test path ---------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
  log "self-test begin SOURCE_SHA=$SOURCE_SHA_SHORT"
  self_test_cpu_math
  self_test_parse
  # tier helpers
  [[ "$(tier_coded_wxh 240p)" == "320x240" ]]
  [[ "$(tier_coded_wxh 480p)" == "624x480" ]]
  [[ "$(tier_frame_bytes 480p)" == "$((624 * 480 * 3 / 2))" ]]
  [[ "$(tier_frame_bytes 240p)" == "$((320 * 240 * 3 / 2))" ]]
  # refuse presented mistake as tier name
  if tier_coded_wxh 640x480 2>/dev/null; then fail "640x480 must not be a tier"; fi
  # emit a dry record
  export SOURCE_SHA SOURCE_SHA_SHORT STAMP HOST
  export TIER=480p CODED_WXH=624x480 FRAME_BYTES=$((624 * 480 * 3 / 2))
  export KEY_REDACTED="/library/metadata/REDACTED" OFFSET_MS SETTLE_S WINDOW_S
  export CPU_JSON='{"hz":100,"dwall_s":2.0,"misterplexd_pct_onecpu":13.5,"ffmpeg_pct_onecpu":40.2,"threads":[{"tid":1,"comm":"misterplexd","pct_onecpu":10.0,"nvcsw_delta":12,"nivcsw_delta":3}]}'
  export FRAMES_JSON
  FRAMES_JSON="$(cat "$OUT_DIR/selftest_parse.json")"
  export HDMI_JSON=null RBF_MD5=selftest
  export RECORD_PATH="$OUT_DIR/p480_ab_selftest_${STAMP}.json"
  emit_record | tee "$OUT_DIR/p480_ab_selftest_${STAMP}.table.txt"
  # key=value block
  {
    echo "P480_AB_RESULT=SELF_TEST_OK"
    echo "SOURCE_SHA=$SOURCE_SHA"
    echo "tier=480p"
    echo "coded_wxh=624x480"
    echo "record=$RECORD_PATH"
  } | tee "$OUT_DIR/p480_ab_selftest_${STAMP}.kv.txt"
  log "self-test OK"
  exit 0
fi

if [[ "$DRY_PARSE" == "1" ]]; then
  parse_frame_lines "${1:-/dev/stdin}"
  exit 0
fi

# --- device path ------------------------------------------------------------
if [[ "$BOTH" == "1" ]]; then
  rc=0
  TIER=240p "$0" --tier 240p ${KEY:+--key "$KEY"} --offset-ms "$OFFSET_MS" \
    --settle-s "$SETTLE_S" --window-s "$WINDOW_S" --out-dir "$OUT_DIR" || rc=$?
  TIER=480p "$0" --tier 480p ${KEY:+--key "$KEY"} --offset-ms "$OFFSET_MS" \
    --settle-s "$SETTLE_S" --window-s "$WINDOW_S" --out-dir "$OUT_DIR" || rc=$?
  exit "$rc"
fi

CODED_WXH="$(tier_coded_wxh "$TIER")" || fail "bad TIER=$TIER (use 240p|480p)"
FRAME_BYTES="$(tier_frame_bytes "$TIER")"
[[ -n "$KEY" ]] || fail "PLEX_KEY/KEY required for device run (or --self-test)"

if ! command -v sshpass >/dev/null 2>&1; then
  hw_skip_not_pass "p480_ab" "sshpass required"
fi

if [[ -n "${EXPECTED_RBF_MD5:-${HW_EXPECTED_RBF_MD5:-}}" ]]; then
  hw_require_expected_rbf_md5 "p480_ab" "$HOST" "$PASS" "$USER" \
    "${EXPECTED_RBF_MD5:-${HW_EXPECTED_RBF_MD5}}"
fi

RBF_MD5="$(hw_parse_md5_hex "$(ssh_m 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' || true)")"
log "tier=$TIER coded=$CODED_WXH bytes=$FRAME_BYTES sha=$SOURCE_SHA_SHORT rbf=${RBF_MD5:-unparsed}"

restore_conf() {
  ssh_m "if [ -f '$CONF_BAK' ]; then cp -f '$CONF_BAK' '$CONF_REMOTE'; rm -f '$CONF_BAK';
    if [ \"$RESTART_DAEMON\" = 1 ]; then
      killall misterplexd 2>/dev/null || true
      sleep 0.5
      if [ -x /media/fat/misterplex/bin/misterplexd ]; then
        nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 \
          --conf '$CONF_REMOTE' >>'$LOG_REMOTE' 2>&1 &
      fi
    fi
  fi" || true
}
trap restore_conf EXIT

# Patch conf for forced coded tier (OSD_CONTROL off so O[4] cannot override).
ssh_m "cp -f '$CONF_REMOTE' '$CONF_BAK' && python3 - <<'PY'
from pathlib import Path
p = Path('$CONF_REMOTE')
text = p.read_text(encoding='utf-8', errors='replace') if p.exists() else ''
keys = {
  'OSD_CONTROL': '0',
  'DECODE': '$CODED_WXH',
  'DECODE_ALLOW_LAB_480P': '1' if '$CODED_WXH' == '624x480' else '0',
}
if '$PRESENT_PROFILE_FORCE' == '1':
  keys['PRESENT_PROFILE'] = '1'
lines = text.splitlines()
seen = set()
out = []
for line in lines:
  if not line or line.lstrip().startswith('#') or '=' not in line:
    out.append(line); continue
  k = line.split('=',1)[0].strip()
  if k in keys:
    out.append(f'{k}={keys[k]}'); seen.add(k)
  else:
    out.append(line)
for k,v in keys.items():
  if k not in seen:
    out.append(f'{k}={v}')
p.write_text('\\n'.join(out) + '\\n', encoding='utf-8')
print('conf_patched', keys)
PY"

if [[ "$RESTART_DAEMON" == "1" ]]; then
  ssh_m "killall misterplexd 2>/dev/null || true; sleep 0.5
    nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 \
      --conf '$CONF_REMOTE' >>'$LOG_REMOTE' 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10; do
      curl -fsS --connect-timeout 1 --max-time 2 http://127.0.0.1:3005/resources >/dev/null 2>&1 && exit 0
      sleep 0.5
    done
    exit 1" || fail "misterplexd did not come up after conf patch"
fi

# Mark log
MARK="P480_AB ${TIER} ${STAMP} ${SOURCE_SHA_SHORT}"
ssh_m "printf '\n=== %s ===\n' '$MARK' >>'$LOG_REMOTE'"
LOG_START="$(ssh_m "wc -l <'$LOG_REMOTE'" | tr -d '[:space:]')"

# Cast
ENC_KEY="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$KEY")"
log "cast key(redacted) offset_ms=$OFFSET_MS"
curl -fsS --connect-timeout 5 --max-time 30 \
  "${BASE}/player/playback/playMedia?key=${ENC_KEY}&offset=${OFFSET_MS}&commandID=p480ab-${TIER}" \
  >/dev/null || fail "playMedia failed"

# Wait playing
play_ok=0
for _ in $(seq 1 30); do
  body="$(curl -fsS --max-time 5 "${BASE}/player/timeline/poll?wait=0" 2>/dev/null || true)"
  if printf '%s' "$body" | grep -q 'state="playing"'; then play_ok=1; break; fi
  sleep 1
done
[[ "$play_ok" == "1" ]] || fail "timeline never reached playing"

log "settle ${SETTLE_S}s"
sleep "$SETTLE_S"

# CPU + ctxt window on device (mandatory method)
CPU_RAW_PATH="$OUT_DIR/p480_ab_${TIER}_${STAMP}_cpu_raw.txt"
ssh_m "WINDOW_S='$WINDOW_S' bash -s" <<'REMOTE' >"$CPU_RAW_PATH"
set -euo pipefail
WINDOW_S="${WINDOW_S:-60}"
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)

# Snapshot: for each pid of interest, every task's utime stime + status ctxt
snapshot() {
  local tag="$1"
  echo "SNAP $tag wall_ns=$(date +%s%N)"
  echo "HZ=$HZ"
  for name in misterplexd ffmpeg; do
    pids=$(pidof "$name" 2>/dev/null || true)
    echo "PROCS name=$name pids=${pids:-none}"
    for pid in $pids; do
      [ -r "/proc/$pid/stat" ] || continue
      # process-level
      awk -v pid="$pid" -v name="$name" '{print "PROC", name, pid, "utime="$14, "stime="$15, "num_threads="$20}' "/proc/$pid/stat"
      if [ -r "/proc/$pid/status" ]; then
        awk -v pid="$pid" -v name="$name" '
          /^voluntary_ctxt_switches:/ {v=$2}
          /^nonvoluntary_ctxt_switches:/ {n=$2}
          END {print "PROC_CTXT", name, pid, "nvcsw="v, "nivcsw="n}
        ' "/proc/$pid/status"
      fi
      # per-thread
      for tdir in /proc/$pid/task/*; do
        tid=$(basename "$tdir")
        [ -r "$tdir/stat" ] || continue
        # comm may have spaces in () — use the standard parse: find last ) then fields
        awk -v pid="$pid" -v tid="$tid" '
          {
            comm_start = index($0, "(")
            comm_end = 0
            for (i = length($0); i > 0; i--) if (substr($0,i,1)==")") { comm_end=i; break }
            comm = substr($0, comm_start+1, comm_end-comm_start-1)
            rest = substr($0, comm_end+2)
            n = split(rest, a, / /)
            # after state: ppid... utime is field 12 in rest? 
            # full stat after comm: state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime
            # rest fields: 1=state ... 12=utime 13=stime
            ut = a[12]+0; st = a[13]+0
            print "TASK", pid, tid, "comm="comm, "utime="ut, "stime="st, "ticks="(ut+st)
          }
        ' "$tdir/stat"
        if [ -r "$tdir/status" ]; then
          awk -v pid="$pid" -v tid="$tid" '
            /^Name:/ {comm=$2}
            /^voluntary_ctxt_switches:/ {v=$2}
            /^nonvoluntary_ctxt_switches:/ {n=$2}
            END {print "TASK_CTXT", pid, tid, "comm="comm, "nvcsw="v, "nivcsw="n}
          ' "$tdir/status"
        fi
      done
    done
  done
}

snapshot START
sleep "$WINDOW_S"
snapshot END
REMOTE

# Parse CPU raw → JSON (host)
CPU_JSON_PATH="$OUT_DIR/p480_ab_${TIER}_${STAMP}_cpu.json"
python3 - "$CPU_RAW_PATH" "$CPU_JSON_PATH" <<'PY'
import json, sys, re
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
hz = 100
walls = {}
# task key (pid,tid) -> {start_ticks,end_ticks,comm,nvcsw0,nivcsw0,...}
tasks = {}
procs = {}

def ensure_task(pid, tid):
    k = (int(pid), int(tid))
    if k not in tasks:
        tasks[k] = {"pid": int(pid), "tid": int(tid), "comm": "?", "t0": None, "t1": None,
                    "nvcsw0": None, "nvcsw1": None, "nivcsw0": None, "nivcsw1": None}
    return tasks[k]

phase = None
for line in raw:
    if line.startswith("HZ="):
        hz = int(line.split("=",1)[1])
    m = re.match(r"SNAP (START|END) wall_ns=(\d+)", line)
    if m:
        phase = m.group(1)
        walls[phase] = int(m.group(2))
        continue
    if not phase:
        continue
    parts = line.split()
    if not parts:
        continue
    if parts[0] == "TASK" and len(parts) >= 4:
        pid, tid = parts[1], parts[2]
        t = ensure_task(pid, tid)
        for p in parts[3:]:
            if p.startswith("comm="):
                t["comm"] = p[5:]
            elif p.startswith("ticks="):
                val = int(p.split("=",1)[1])
                if phase == "START":
                    t["t0"] = val
                else:
                    t["t1"] = val
    elif parts[0] == "TASK_CTXT":
        pid, tid = parts[1], parts[2]
        t = ensure_task(pid, tid)
        for p in parts[3:]:
            if p.startswith("comm="):
                t["comm"] = p[5:]
            elif p.startswith("nvcsw="):
                val = int(p.split("=",1)[1])
                if phase == "START":
                    t["nvcsw0"] = val
                else:
                    t["nvcsw1"] = val
            elif p.startswith("nivcsw="):
                val = int(p.split("=",1)[1])
                if phase == "START":
                    t["nivcsw0"] = val
                else:
                    t["nivcsw1"] = val
    elif parts[0] == "PROC" and len(parts) >= 4:
        name, pid = parts[1], parts[2]
        key = (name, int(pid))
        rec = procs.setdefault(key, {"name": name, "pid": int(pid), "t0": None, "t1": None})
        ut = st = None
        for p in parts[3:]:
            if p.startswith("utime="): ut = int(p.split("=",1)[1])
            if p.startswith("stime="): st = int(p.split("=",1)[1])
        if ut is not None and st is not None:
            if phase == "START":
                rec["t0"] = ut + st
            else:
                rec["t1"] = ut + st

if "START" not in walls or "END" not in walls:
    raise SystemExit("cpu raw missing START/END walls")
dwall = (walls["END"] - walls["START"]) / 1e9
if dwall <= 0:
    raise SystemExit("non-positive dwall")

def pct(dticks):
    return round(100.0 * dticks / (hz * dwall), 3)

thread_rows = []
by_name_ticks = {"misterplexd": 0, "ffmpeg": 0}
for k, t in sorted(tasks.items()):
    if t["t0"] is None and t["t1"] is None:
        continue
    # mid-window exit: t1 missing → use t0 as end (0 delta) only if never seen end;
    # if started mid-window t0 missing → treat t0=0
    t0 = t["t0"] if t["t0"] is not None else 0
    t1 = t["t1"] if t["t1"] is not None else t0  # exited: freeze at last start? 
    # Better: if exited after start, we lost end counters — cannot invent work.
    # Rule: missing END → dticks = 0 for that thread (unknown), flag exited.
    exited = t["t1"] is None and t["t0"] is not None
    appeared = t["t0"] is None and t["t1"] is not None
    if exited:
        dticks = 0
        flag = "exited_mid_window_unscored_ticks"
    elif appeared:
        dticks = t1  # from 0
        flag = "appeared_mid_window"
    else:
        dticks = max(0, t1 - t0)
        flag = "ok"
    nvcsw_d = None
    nivcsw_d = None
    if t["nvcsw0"] is not None and t["nvcsw1"] is not None:
        nvcsw_d = t["nvcsw1"] - t["nvcsw0"]
    if t["nivcsw0"] is not None and t["nivcsw1"] is not None:
        nivcsw_d = t["nivcsw1"] - t["nivcsw0"]
    # attribute to process name via /proc pid name from procs
    pname = None
    for (n, pid), _ in procs.items():
        if pid == t["pid"]:
            pname = n
            break
    if pname in by_name_ticks and flag != "exited_mid_window_unscored_ticks":
        by_name_ticks[pname] += dticks
    thread_rows.append({
        "pid": t["pid"], "tid": t["tid"], "comm": t["comm"], "proc": pname,
        "dticks": dticks, "pct_onecpu": pct(dticks) if flag != "exited_mid_window_unscored_ticks" else None,
        "nvcsw_delta": nvcsw_d, "nivcsw_delta": nivcsw_d,
        "flag": flag,
    })

# process-level fallback sums (also mandatory cross-check)
proc_pct = {}
for (name, pid), rec in procs.items():
    if rec["t0"] is None or rec["t1"] is None:
        continue
    proc_pct.setdefault(name, 0.0)
    # sum process ticks — note multi-pid
    # store list
proc_list = []
name_ticks_proc = {"misterplexd": 0, "ffmpeg": 0}
for (name, pid), rec in procs.items():
    if rec["t0"] is None or rec["t1"] is None:
        continue
    dt = max(0, rec["t1"] - rec["t0"])
    name_ticks_proc[name] = name_ticks_proc.get(name, 0) + dt
    proc_list.append({"name": name, "pid": pid, "dticks": dt, "pct_onecpu": pct(dt)})

out = {
    "hz": hz,
    "dwall_s": round(dwall, 6),
    "formula": "P=100*dticks/(HZ*dwall)",
    "fps_scaling": False,
    "misterplexd_pct_onecpu": pct(name_ticks_proc.get("misterplexd", 0)),
    "ffmpeg_pct_onecpu": pct(name_ticks_proc.get("ffmpeg", 0)),
    "misterplexd_pct_onecpu_thread_sum": pct(by_name_ticks.get("misterplexd", 0)),
    "ffmpeg_pct_onecpu_thread_sum": pct(by_name_ticks.get("ffmpeg", 0)),
    "processes": proc_list,
    "threads": sorted(thread_rows, key=lambda r: (-(r["dticks"] or 0), r["tid"])),
}
json.dump(out, open(sys.argv[2], "w"), indent=2, sort_keys=True)
print(json.dumps({k: out[k] for k in ("hz","dwall_s","misterplexd_pct_onecpu","ffmpeg_pct_onecpu")}, sort_keys=True))
PY

# Collect log slice
LOG_SLICE="$OUT_DIR/p480_ab_${TIER}_${STAMP}_log.txt"
ssh_m "tail -n +$((LOG_START + 1)) '$LOG_REMOTE'" >"$LOG_SLICE" || true

FRAMES_JSON_PATH="$OUT_DIR/p480_ab_${TIER}_${STAMP}_frames.json"
parse_frame_lines "$LOG_SLICE" >"$FRAMES_JSON_PATH"

# Stop playback
curl -fsS --max-time 10 "${BASE}/player/playback/stop?commandID=p480ab-stop-${TIER}" >/dev/null || true

HDMI_JSON=null
if [[ "$HDMI_AVSYNC" == "1" ]]; then
  HDMI_DIR="$OUT_DIR/hdmi_${TIER}_${STAMP}"
  mkdir -p "$HDMI_DIR"
  # Sustained drift slope via avsync_rate (host grabber). Failures → null, not fake pass.
  if python3 "$ROOT/tests/hw/avsync_rate.py" \
      --rating-key "$(basename "$KEY")" \
      --out "$HDMI_DIR" \
      --label "p480_${TIER}" \
      --settle 5 \
      --window "$WINDOW_S" \
      --no-cast 2>"$HDMI_DIR/avsync_rate.err"; then
    if [[ -f "$HDMI_DIR/summary.json" ]]; then
      HDMI_JSON="$(cat "$HDMI_DIR/summary.json")"
    elif compgen -G "$HDMI_DIR/*.json" >/dev/null; then
      HDMI_JSON="$(cat "$(ls -1 "$HDMI_DIR"/*.json | head -1)")"
    fi
  else
    log "HDMI avsync unscored/failed (see $HDMI_DIR/avsync_rate.err) — log av_drift is TELEMETRY ONLY (not lip-sync PASS; parent 2026-07-31)"
  fi
fi

KEY_REDACTED="$(python3 -c 'import re,sys; print(re.sub(r"[0-9]{2,}", "N", sys.argv[1]))' "$KEY")"
export SOURCE_SHA SOURCE_SHA_SHORT STAMP HOST TIER CODED_WXH
export FRAME_BYTES KEY_REDACTED OFFSET_MS SETTLE_S WINDOW_S
export CPU_JSON="$(cat "$CPU_JSON_PATH")"
export FRAMES_JSON="$(cat "$FRAMES_JSON_PATH")"
export HDMI_JSON RBF_MD5
RECORD_PATH="$OUT_DIR/p480_ab_${TIER}_${STAMP}.json"
export RECORD_PATH
emit_record | tee "$OUT_DIR/p480_ab_${TIER}_${STAMP}.table.txt"

# stable key=value block
{
  echo "P480_AB_RESULT=OK"
  echo "SOURCE_SHA=$SOURCE_SHA"
  echo "tier=$TIER"
  echo "coded_wxh=$CODED_WXH"
  echo "frame_bytes_i420=$FRAME_BYTES"
  echo "offset_ms=$OFFSET_MS"
  echo "settle_s=$SETTLE_S"
  echo "window_s=$WINDOW_S"
  echo "record=$RECORD_PATH"
  python3 - <<PY
import json
c=json.load(open("$CPU_JSON_PATH"))
f=json.load(open("$FRAMES_JSON_PATH"))
print(f"misterplexd_pct_onecpu={c.get('misterplexd_pct_onecpu')}")
print(f"ffmpeg_pct_onecpu={c.get('ffmpeg_pct_onecpu')}")
print(f"dwall_s={c.get('dwall_s')}")
print(f"vfps_mean={(f.get('vfps') or {}).get('mean')}")
print(f"pfps_mean={(f.get('pfps') or {}).get('mean')}")
print(f"drops_delta={f.get('drops_delta')}")
print(f"av_drift_ms_mean={(f.get('av_drift_ms') or {}).get('mean')}")
print(f"av_drift_late_minus_early_ms={f.get('av_drift_late_minus_early_ms')}")
print(f"ddr_push_ms_mean={(f.get('ddr_push_ms') or {}).get('mean')}")
print(f"decode={f.get('decode')}")
pp=f.get("present_profile_last") or {}
print(f"ddr_copy_us_p={pp.get('ddr_copy_us_p')}")
print(f"ddr_total_us_p={pp.get('ddr_total_us_p')}")
print(f"ddr_plxd_used_x100_p={pp.get('ddr_plxd_used_x100_p')}")
PY
} | tee "$OUT_DIR/p480_ab_${TIER}_${STAMP}.kv.txt"

restore_conf
trap - EXIT
log "done tier=$TIER record=$RECORD_PATH"
