#!/usr/bin/env bash
# Cast target mismatch: pure unit + HTTP harness + red twin (accept-all fault).
# No real PMS required — local stub controller via curl.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILD="$ROOT/build"
WORK="$BUILD/cast-target-unit"
mkdir -p "$WORK" "$BUILD"

CXX_BIN="${CXX:-g++}"
CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")

# --- 1) Green pure unit ---
"$CXX_BIN" "${CXX_FLAGS[@]}" -o "$BUILD/test_cast_target" "$ROOT/tests/unit/test_cast_target.cpp"
"$BUILD/test_cast_target"
echo "PASS test_cast_target pure unit"

# --- 2) Red twin: CAST_TARGET_FAULT_ACCEPT_ALL must FAIL the mismatch CHECK ---
"$CXX_BIN" "${CXX_FLAGS[@]}" -DCAST_TARGET_FAULT_ACCEPT_ALL \
  -o "$WORK/test_cast_target_fault" "$ROOT/tests/unit/test_cast_target.cpp"
set +e
OUT="$("$WORK/test_cast_target_fault" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: accept-all fault unexpectedly passed (vacuous / check missing)" >&2
  exit 1
fi
grep -q 'castTargetAccepted' <<<"$OUT" || {
  echo "FAIL: red twin did not hit castTargetAccepted guard" >&2
  exit 1
}
echo "RED OK: accept-all mutant fails mismatch reject (rc=$RC)"

# --- 3) HTTP harness: local daemon as cast target; curl is the stub controller ---
make -C "$ROOT" plexd >/dev/null
BIN="$ROOT/build/misterplexd"
PORT=$(python3 - <<'PY'
import socket
for p in range(13200, 13350):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", p))
        print(p)
        s.close()
        break
    except OSError:
        s.close()
else:
    raise SystemExit("no free port")
PY
)
LOG="$WORK/daemon.log"
: >"$LOG"
"$BIN" --name CastHarness --id misterplex-dev --port "$PORT" >"$LOG" 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT

ok=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PORT}/resources" >/dev/null 2>&1; then
    ok=1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
if [[ "$ok" != 1 ]]; then
  echo "FAIL: harness daemon not up on :$PORT" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

# Bind check: must not be loopback-only in code (INADDR_ANY). Score via source.
grep -q 'INADDR_ANY' "$ROOT/arm/misterplexd/companion.cpp" || {
  echo "FAIL: companion HTTP/GDM not binding INADDR_ANY" >&2
  exit 1
}
echo "PASS companion binds INADDR_ANY (not loopback-only)"

# Matching target → 200 timeline
set +e
GOOD=$(curl -sS -o "$WORK/good.body" -w "%{http_code}" \
  -H "X-Plex-Target-Client-Identifier: misterplex-dev" \
  "http://127.0.0.1:${PORT}/player/timeline/subscribe?commandID=1")
set -e
echo "subscribe_match http=$GOOD"
if [[ "$GOOD" != "200" ]]; then
  echo "FAIL: matching target subscribe want 200 got $GOOD" >&2
  cat "$WORK/good.body" >&2 || true
  exit 1
fi
grep -q 'machineIdentifier="misterplex-dev"' "$WORK/good.body" || {
  echo "FAIL: timeline missing machineIdentifier=misterplex-dev" >&2
  cat "$WORK/good.body" >&2
  exit 1
}
echo "PASS matching target subscribe → 200 + id"

# PREDICTION was: pre-fix accepted mismatch with 200 silently.
# POST-FIX: mismatch must be 409 + CAST_TARGET_MISMATCH (loud).
set +e
BAD=$(curl -sS -o "$WORK/bad.body" -w "%{http_code}" \
  -H "X-Plex-Target-Client-Identifier: misterplex-1" \
  "http://127.0.0.1:${PORT}/player/timeline/subscribe?commandID=2")
set -e
echo "subscribe_mismatch http=$BAD body=$(head -c 200 "$WORK/bad.body")"
if [[ "$BAD" != "409" ]]; then
  echo "FAIL: mismatched target want HTTP 409 got $BAD (still silent-accept?)" >&2
  cat "$WORK/bad.body" >&2 || true
  exit 1
fi
grep -q 'CAST_TARGET_MISMATCH' "$WORK/bad.body" || {
  echo "FAIL: body missing CAST_TARGET_MISMATCH" >&2
  cat "$WORK/bad.body" >&2
  exit 1
}
grep -q 'expected=misterplex-dev' "$WORK/bad.body" || {
  echo "FAIL: body missing expected=misterplex-dev" >&2
  exit 1
}
grep -q 'got=misterplex-1' "$WORK/bad.body" || {
  echo "FAIL: body missing got=misterplex-1" >&2
  exit 1
}
# Daemon log must also be loud (user cannot see HTTP body on a phone).
grep -q 'ERROR CAST_TARGET_MISMATCH' "$LOG" || {
  echo "FAIL: daemon log missing ERROR CAST_TARGET_MISMATCH" >&2
  cat "$LOG" >&2
  exit 1
}
echo "PASS mismatched target → 409 + loud ERROR CAST_TARGET_MISMATCH"

# No target header still works (lab /resources path already did; poll too).
set +e
NOTARGET=$(curl -sS -o "$WORK/nt.body" -w "%{http_code}" \
  "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=3")
set -e
echo "subscribe_notarget http=$NOTARGET"
if [[ "$NOTARGET" != "200" ]]; then
  echo "FAIL: no-target poll want 200 got $NOTARGET" >&2
  exit 1
fi
echo "PASS no-target poll still 200"

# Audit probes: trailing OWS and percent-encoded query must ACCEPT (were 409).
set +e
# curl trims header values in some builds — send raw request via python.
TRAIL=$(python3 - <<PY
import socket
req = (
    "GET /player/timeline/subscribe?commandID=4 HTTP/1.1\r\n"
    "Host: 127.0.0.1:${PORT}\r\n"
    "X-Plex-Target-Client-Identifier: misterplex-dev   \r\n"
    "Connection: close\r\n"
    "\r\n"
)
s = socket.create_connection(("127.0.0.1", int("${PORT}")), 3)
s.sendall(req.encode())
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
s.close()
line = data.split(b"\r\n", 1)[0].decode("latin1", "replace")
print(line.split(" ", 2)[1] if line.startswith("HTTP/") else "000")
PY
)
set -e
echo "subscribe_trailing_ows http=$TRAIL"
if [[ "$TRAIL" != "200" ]]; then
  echo "FAIL: trailing OWS target want 200 got $TRAIL (still over-strict?)" >&2
  exit 1
fi
echo "PASS trailing OWS on target header → 200"

set +e
PCT=$(curl -sS -o "$WORK/pct.body" -w "%{http_code}" \
  "http://127.0.0.1:${PORT}/player/timeline/subscribe?commandID=5&X-Plex-Target-Client-Identifier=misterplex%2Ddev")
set -e
echo "subscribe_pct_query http=$PCT"
if [[ "$PCT" != "200" ]]; then
  echo "FAIL: percent-encoded query target want 200 got $PCT" >&2
  cat "$WORK/pct.body" >&2 || true
  exit 1
fi
echo "PASS percent-encoded query target → 200"

# Wrong target on /resources must still 200 (discovery open).
set +e
RESBAD=$(curl -sS -o "$WORK/resbad.body" -w "%{http_code}" \
  -H "X-Plex-Target-Client-Identifier: misterplex-1" \
  "http://127.0.0.1:${PORT}/resources")
set -e
echo "resources_mismatch http=$RESBAD"
if [[ "$RESBAD" != "200" ]]; then
  echo "FAIL: /resources with wrong target want 200 got $RESBAD" >&2
  exit 1
fi
echo "PASS /resources stays open with wrong target header"

# --- TCP fragmentation: split target header at every byte of the id value ---
# Reviewer probe: write "misterplex-" then "dev..." → was 409 CAST_TARGET_MISMATCH
# got=misterplex-. Full header block buffering must accept all splits → 200.
TARGET_ID="misterplex-dev"
# One Python process: split target value at every byte index (reviewer recommendation).
split_report=$(TARGET_ID="$TARGET_ID" PORT="$PORT" python3 - <<'PY'
import os, socket, time, sys
port = int(os.environ["PORT"])
tid = os.environ["TARGET_ID"].encode()
ok = fail = 0
for split in range(0, len(tid) + 1):
    left, right = tid[:split], tid[split:]
    pre = (
        b"GET /player/timeline/subscribe?commandID=9 HTTP/1.1\r\n"
        b"Host: 127.0.0.1\r\n"
        b"X-Plex-Target-Client-Identifier: "
    )
    post = b"\r\nConnection: close\r\n\r\n"
    s = socket.create_connection(("127.0.0.1", port), 3)
    s.sendall(pre + left)
    time.sleep(0.015)
    s.sendall(right + post)
    s.settimeout(3.0)
    data = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    s.close()
    line = data.split(b"\r\n", 1)[0].decode("latin1", "replace") if data else ""
    code = line.split(" ", 2)[1] if line.startswith("HTTP/") else "000"
    if code != "200":
        fail += 1
        print(f"FAIL split@{split} left={left!r} right={right!r} http={code}", file=sys.stderr)
    else:
        ok += 1
print(f"ok={ok} fail={fail} n={len(tid)+1}")
sys.exit(1 if fail else 0)
PY
); split_rc=$?
echo "split_target_scans $split_report"
if [[ "$split_rc" -ne 0 ]]; then
  echo "FAIL: TCP-split target header still rejected" >&2
  grep -E 'CAST_TARGET|header read' "$LOG" | tail -20 >&2 || true
  exit 1
fi
echo "PASS TCP-split target value at every byte → 200"

# Extra: multi-chunk entire request (3 writes) still 200
code=$(python3 - <<PY
import socket, time
port = int("${PORT}")
parts = [
    b"GET /player/timeline/subscribe?commandID=10 HTTP/1.1\r\nHost: 127.0.0.1\r\n",
    b"X-Plex-Target-Client-Identifier: misterplex-",
    b"dev\r\nConnection: close\r\n\r\n",
]
s = socket.create_connection(("127.0.0.1", port), 3)
for p in parts:
    s.sendall(p)
    time.sleep(0.015)
s.settimeout(3.0)
data = b""
try:
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
except socket.timeout:
    pass
s.close()
line = data.split(b"\r\n", 1)[0].decode("latin1", "replace") if data else ""
print(line.split(" ", 2)[1] if line.startswith("HTTP/") else "000")
PY
)
echo "split_reviewer_shape http=$code"
if [[ "$code" != "200" ]]; then
  echo "FAIL: reviewer-shape split (misterplex-|dev) want 200 got $code" >&2
  exit 1
fi
echo "PASS reviewer-shape mid-id TCP split → 200"

# Incomplete headers that never finish should not hang forever (timeout → 408).
code=$(python3 - <<PY
import socket
port = int("${PORT}")
s = socket.create_connection(("127.0.0.1", port), 3)
s.sendall(b"GET /player/timeline/poll HTTP/1.1\r\nX-Plex-Target-Client-Identifier: misterplex-")
# never send rest; daemon must time out
s.settimeout(8.0)
data = b""
try:
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
except socket.timeout:
    pass
s.close()
line = data.split(b"\r\n", 1)[0].decode("latin1", "replace") if data else ""
print(line.split(" ", 2)[1] if line.startswith("HTTP/") else "000")
PY
)
echo "incomplete_headers http=$code"
if [[ "$code" != "408" ]]; then
  echo "FAIL: incomplete headers want 408 got $code" >&2
  exit 1
fi
echo "PASS incomplete headers → 408 (no hang, no false 409)"

# Concurrent: incomplete connection held open must NOT stall a valid /resources.
# Pre-fix (sync accept loop): /resources delayed ~4.8s behind one incomplete client.
# Post-fix: worker-per-connection → /resources promptly while incomplete still open.
conc=$(PORT="$PORT" python3 - <<'PY'
import os, socket, time, sys
port = int(os.environ["PORT"])
# Hold incomplete connection open (do not finish headers).
slow = socket.create_connection(("127.0.0.1", port), 3)
slow.sendall(b"GET /player/timeline/poll HTTP/1.1\r\nX-Plex-Target-Client-Identifier: misterplex-")
time.sleep(0.05)  # ensure accept thread handed off to worker
t0 = time.perf_counter()
fast = socket.create_connection(("127.0.0.1", port), 3)
fast.sendall(
    b"GET /resources HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
)
fast.settimeout(2.0)
data = b""
try:
    while True:
        c = fast.recv(4096)
        if not c:
            break
        data += c
except socket.timeout:
    pass
fast.close()
ms = (time.perf_counter() - t0) * 1000.0
line = data.split(b"\r\n", 1)[0].decode("latin1", "replace") if data else ""
code = line.split(" ", 2)[1] if line.startswith("HTTP/") else "000"
# cleanup slow (may get 408 later)
try:
    slow.close()
except Exception:
    pass
print(f"http={code} ms={ms:.1f}")
# Fail if delayed like the audit (~4800ms) or not 200
if code != "200":
    sys.exit(2)
if ms > 500:  # soft bound; audit was ~4800; healthy is typically <50ms
    sys.exit(3)
sys.exit(0)
PY
); conc_rc=$?
echo "concurrent_resources_during_incomplete $conc"
if [[ "$conc_rc" -eq 2 ]]; then
  echo "FAIL: concurrent /resources not 200 while incomplete open" >&2
  exit 1
fi
if [[ "$conc_rc" -eq 3 ]]; then
  echo "FAIL: concurrent /resources too slow (still blocked by incomplete client?)" >&2
  exit 1
fi
if [[ "$conc_rc" -ne 0 ]]; then
  echo "FAIL: concurrent probe rc=$conc_rc" >&2
  exit 1
fi
# Sub-100ms is the parent bar when healthy; report actual ms.
ms_val=$(sed -n 's/.*ms=\([0-9.]*\).*/\1/p' <<<"$conc")
python3 - <<PY
ms=float("${ms_val}")
print(f"concurrent_ms={ms:.1f}")
raise SystemExit(0 if ms < 100.0 else 4)
PY
conc_fast=$?
if [[ "$conc_fast" -ne 0 ]]; then
  echo "FAIL: concurrent /resources ms=${ms_val} want <100 (parent bar)" >&2
  exit 1
fi
echo "PASS concurrent /resources <100ms while incomplete client open"

echo "OK cast target mismatch gate (pure + HTTP harness + red twin + TCP-split + concurrent)"
