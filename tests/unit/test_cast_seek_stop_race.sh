#!/usr/bin/env bash
# Concurrent seekTo + stop must not leave demux running after stop.
# Pre-fix: seek thread calls seekMs/doPlay after stop → ffmpeg alive, timeline idle.
# Product path: seekGen bump on stop + wantPlay re-check → 0 persistent restarts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILD="$ROOT/build"
WORK="$BUILD/cast-seek-stop-race"
mkdir -p "$WORK" "$BUILD"

CXX_BIN="${CXX:-g++}"
CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -pthread)

# --- Model unit: green + RED twin ---
"$CXX_BIN" "${CXX_FLAGS[@]}" -o "$BUILD/test_cast_seek_stop_serialize" \
  "$ROOT/tests/unit/test_cast_seek_stop_serialize.cpp"
"$BUILD/test_cast_seek_stop_serialize"
echo "model_green true rc=$?"

"$CXX_BIN" "${CXX_FLAGS[@]}" -DCAST_SEEK_STOP_FAULT \
  -o "$BUILD/test_cast_seek_stop_serialize_fault" \
  "$ROOT/tests/unit/test_cast_seek_stop_serialize.cpp"
"$BUILD/test_cast_seek_stop_serialize_fault"
echo "model_red true rc=$?"

# --- Integration against product daemon ---
make -C "$ROOT" plexd >/dev/null
BIN="$ROOT/build/misterplexd"

PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)
LOG="$WORK/daemon.log"
: >"$LOG"

export PRESENT=none
export DECODE=320x240
export STREAM=0
export OSD_CONTROL=0
FFMPEG_BIN="$(command -v ffmpeg || true)"
CLIP="$ROOT/assets/avsync/sync_trekmatch_320x240_24_blip.mp4"
if [[ ! -f "$CLIP" ]]; then
  CLIP=""
fi

"$BIN" --name SeekStopRace --id misterplex-dev --port "$PORT" \
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

if [[ -n "$CLIP" ]]; then
  KEY_Q=$(python3 - <<PY
import urllib.parse
print("key=" + urllib.parse.quote("file:$CLIP", safe=""))
PY
)
else
  KEY_Q="key=%2Flibrary%2Fmetadata%2F1"
fi

export PORT PID KEY_Q
python3 - <<'PY'
import concurrent.futures, os, re, subprocess, sys, time, urllib.request

port = int(os.environ["PORT"])
pid = int(os.environ["PID"])
key_q = os.environ["KEY_Q"]
base = f"http://127.0.0.1:{port}"
hdr = {"X-Plex-Target-Client-Identifier": "misterplex-dev"}

def req(path, timeout=8):
    r = urllib.request.Request(base + path, headers=hdr)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")

def timeline_state():
    _, body = req("/player/timeline/poll?commandID=99")
    m = re.search(r'state="([^"]+)"', body)
    return m.group(1) if m else "missing"

def ffmpeg_live():
    try:
        out = subprocess.check_output(
            ["ps", "-o", "pid=,stat=,args=", "--ppid", str(pid)],
            text=True, stderr=subprocess.DEVNULL)
    except Exception:
        out = subprocess.getoutput(f"ps --ppid {pid} -o pid=,stat=,args=")
    live = 0
    for ln in out.splitlines():
        if "ffmpeg" not in ln.lower():
            continue
        parts = ln.split(None, 2)
        stat = parts[1] if len(parts) > 1 else ""
        if "<defunct>" in ln or "Z" in stat:
            continue
        live += 1
    return live > 0

def plant():
    req(f"/player/playback/playMedia?{key_q}&commandID=1&offset=0")

N = 30
persist_fail = 0
first_fail_detail = None
for i in range(N):
    plant()
    time.sleep(0.2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = []
        for k in range(4):
            off = 1000 * (k + 1) + i * 17
            futs.append(ex.submit(
                req, f"/player/playback/seekTo?offset={off}&commandID={1000+i*10+k}"))
        futs.append(ex.submit(req, f"/player/playback/stop?commandID={2000+i}"))
        futs.append(ex.submit(
            req, f"/player/playback/seekTo?offset={5000+i}&commandID={3000+i}"))
        for f in concurrent.futures.as_completed(futs):
            try:
                code, _ = f.result()
                if code != 200:
                    print(f"WARN http {code} iter {i}", file=sys.stderr)
            except Exception as e:
                print(f"WARN exc {e} iter {i}", file=sys.stderr)

    t0 = time.time()
    still = False
    while time.time() - t0 < 4.0:
        if not ffmpeg_live():
            still = False
            break
        still = True
        time.sleep(0.05)
    if still and ffmpeg_live():
        persist_fail += 1
        st = timeline_state()
        detail = f"iter={i} timeline={st} elapsed_ms={int((time.time()-t0)*1000)}"
        if first_fail_detail is None:
            first_fail_detail = detail
        print(f"FAIL {detail}: ffmpeg still running after stop", file=sys.stderr)
        try:
            req("/player/playback/stop?commandID=9999")
        except Exception:
            pass
        time.sleep(0.4)

print(f"seek_stop_rounds={N} persist_fail={persist_fail} first_fail={first_fail_detail}")
if persist_fail:
    sys.exit(1)
print("PASS concurrent seek/stop (no demux restart persisting after stop)")
PY
echo "integration true rc=$?"
echo "OK cast seek/stop race"
