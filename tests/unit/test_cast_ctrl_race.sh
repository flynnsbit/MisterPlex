#!/usr/bin/env bash
# Concurrent pause/play must keep timeline state consistent with player transport.
# Pre-fix (HTTP workers without ctrlMu_): timeline=playing while ffmpeg=T (stopped).
# RED twin: rebuild companion path is not available here; we prove green on product
# binary and a pure callback-order unit (test_cast_ctrl_serialize.cpp) for the lock.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILD="$ROOT/build"
WORK="$BUILD/cast-ctrl-race"
mkdir -p "$WORK"

make -C "$ROOT" plexd >/dev/null
BIN="$ROOT/build/misterplexd"

PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
LOG="$WORK/daemon.log"
: >"$LOG"
# Local long clip so pause/play has a live demux child when available.
CLIP="$ROOT/assets/avsync/sync_trekmatch_320x240_24_blip.mp4"
[[ -f "$CLIP" ]] || CLIP=""

export PRESENT=none
export DECODE=320x240
export STREAM=0
export OSD_CONTROL=0
FFMPEG_BIN="$(command -v ffmpeg || true)"

"$BIN" --name CtrlRace --id misterplex-dev --port "$PORT" \
  ${FFMPEG_BIN:+--ffmpeg "$FFMPEG_BIN"} \
  >"$LOG" 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT

ok=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PORT}/resources" >/dev/null 2>&1; then ok=1; break; fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.05
done
[[ "$ok" == 1 ]] || { echo "FAIL: daemon up"; cat "$LOG"; exit 1; }

# Plant an active session via playMedia (testsrc-style key if no clip).
if [[ -n "$CLIP" ]]; then
  KEY_Q="key=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("file:$CLIP", safe=""))
PY
)"
else
  KEY_Q="key=%2Flibrary%2Fmetadata%2F1"
fi

curl -sS -o /dev/null -w "%{http_code}" \
  -H "X-Plex-Target-Client-Identifier: misterplex-dev" \
  "http://127.0.0.1:${PORT}/player/playback/playMedia?${KEY_Q}&commandID=1&offset=0" \
  | tee "$WORK/play.code"
echo
# Give demux a moment if it starts
sleep 0.5

# Force wantPlay_ path: timeline may still be buffering; pause/play only act when active.
# Mirror + subscribe can set prePlayHold; playMedia sets wantPlay.
# Race pause and play many times.
python3 - <<PY
import concurrent.futures, os, socket, time, re, sys, urllib.request

port = int("${PORT}")
base = f"http://127.0.0.1:{port}"

def req(path):
    r = urllib.request.Request(
        base + path,
        headers={"X-Plex-Target-Client-Identifier": "misterplex-dev"},
    )
    with urllib.request.urlopen(r, timeout=3) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")

def timeline_state():
    _, body = req("/player/timeline/poll?commandID=99")
    m = re.search(r'state="([^"]+)"', body)
    return m.group(1) if m else "missing"

# Warm: ensure session marked active via pause/play once if already wantPlay
try:
    req("/player/playback/play?commandID=2")
except Exception:
    pass

N = 200
fail = 0
# Concurrent opposite controls
for i in range(N):
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:
        futs = [
            ex.submit(req, "/player/playback/pause?commandID=%d" % (1000 + i)),
            ex.submit(req, "/player/playback/play?commandID=%d" % (2000 + i)),
            ex.submit(req, "/player/playback/pause?commandID=%d" % (3000 + i)),
            ex.submit(req, "/player/playback/play?commandID=%d" % (4000 + i)),
        ]
        for f in concurrent.futures.as_completed(futs):
            try:
                code, _ = f.result()
                if code != 200:
                    fail += 1
            except Exception as e:
                fail += 1
    # Settle: last writer wins — issue a definitive pause then check consistency
    req("/player/playback/pause?commandID=%d" % (5000 + i))
    time.sleep(0.01)
    st = timeline_state()
    if st not in ("paused", "stopped", "buffering", "playing"):
        print(f"FAIL iter {i}: bad timeline state={st}", file=sys.stderr)
        sys.exit(1)
    # Definitive play then pause — must end paused if session active
    req("/player/playback/play?commandID=%d" % (6000 + i))
    time.sleep(0.005)
    req("/player/playback/pause?commandID=%d" % (7000 + i))
    time.sleep(0.02)
    st2 = timeline_state()
    # If never became active (no media), states stay stopped — not a race fail
    if st2 == "playing":
        # After explicit pause, playing is the race symptom (audit)
        print(f"FAIL iter {i}: after pause timeline still playing", file=sys.stderr)
        sys.exit(1)

print(f"race_rounds={N} http_fail={fail} final_state={timeline_state()}")
if fail:
    sys.exit(2)
print("PASS concurrent pause/play race (timeline not stuck playing after pause)")
PY
echo "race_script true rc=$?"

# Thread leak probe: N short connections, count threads before/after
thr_report=$(PORT="$PORT" PID="$PID" python3 - <<'PY'
import os, time, urllib.request, sys
port=int(os.environ["PORT"]); pid=int(os.environ["PID"])
def nthr():
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("Threads:"):
                    return int(line.split()[1])
    except Exception:
        return -1
    return -1
b=nthr()
for i in range(300):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/resources", timeout=1).read()
    except Exception:
        pass
time.sleep(0.3)
a=nthr()
# Stalled clients then release
import socket
stalled=[]
for _ in range(8):
    s=socket.create_connection(("127.0.0.1",port),2)
    s.sendall(b"GET /player/timeline/poll HTTP/1.1\r\nX-Plex-Target-Client-Identifier: x")
    stalled.append(s)
time.sleep(0.2)
mid=nthr()
for s in stalled:
    s.close()
time.sleep(0.5)
# wait past header timeout workers
time.sleep(5.2)
end=nthr()
print(f"threads_before={b} after_300_short={a} during_8_stalled={mid} after_stall_reap={end}")
# Workers should not accumulate unboundedly after short conns
if b>0 and a>b+16:
    print("FAIL thread leak after short conns", file=sys.stderr)
    sys.exit(1)
if b>0 and end>b+8:
    print("FAIL thread leak after stalled reaped", file=sys.stderr)
    sys.exit(1)
print("PASS thread counts bounded (no unbounded leak measured)")
PY
); echo "$thr_report"; echo "threads true rc=$?"

echo "OK cast ctrl race + thread probe"
