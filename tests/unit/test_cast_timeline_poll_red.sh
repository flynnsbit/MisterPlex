#!/usr/bin/env bash
# Unit: red-mutation test for test_cast_timeline_poll.sh
#
# Subtest 1: Full Python mock serves all gate endpoints; CAST_FAIL_INJECT=1
#   exercises the assertion hook without live hardware.
# Subtest 2: Same mock but always returns state="paused" time="0" (exact XML
#   from the live bug report). Gate must exit 1 (FAIL), not 0 (PASS).
#
# Uses DAEMON_BASE env var to route the gate to the mock server so all
# connectivity checks pass. Does NOT require live hardware.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${ROOT}/tests/hw/test_cast_timeline_poll.sh"
INJECT_MOCK_PID=""
MOCK_PID=""

cleanup() {
  [[ -n "$INJECT_MOCK_PID" ]] && kill "$INJECT_MOCK_PID" 2>/dev/null || true
  [[ -n "$MOCK_PID" ]]        && kill "$MOCK_PID"        2>/dev/null || true
}
trap cleanup EXIT

[[ -x "$GATE" ]] || { echo "FAIL: gate not executable at $GATE" >&2; exit 1; }

# ── port picker helper ────────────────────────────────────────────────────────
pick_port() {
  python3 - "$1" "$2" <<'PY'
import sys, socket
lo, hi = int(sys.argv[1]), int(sys.argv[2])
for p in range(lo, hi):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", p)); print(p); s.close(); break
    except OSError:
        s.close()
else:
    raise SystemExit(f"no free port {lo}-{hi}")
PY
}

# ── subtest 1: CAST_FAIL_INJECT via minimal mock ──────────────────────────────
echo "=== red-subtest-1: CAST_FAIL_INJECT=1 ==="
MOCK_PORT1=$(pick_port 19005 19100)
echo "  mock port: $MOCK_PORT1"

python3 <(cat << 'PYEOF'
import sys, http.server, threading

XML = (b'<?xml version="1.0" encoding="UTF-8"?>'
       b'<MediaContainer machineIdentifier="mock-inject" size="1" commandID="1">'
       b'<Timeline type="video" state="stopped" time="0" duration="0" /></MediaContainer>')

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","application/xml")
        self.send_header("Content-Length",str(len(XML))); self.end_headers(); self.wfile.write(XML)
    def log_message(self, *a): pass

p = int(sys.argv[1]) if len(sys.argv)>1 else 19005
srv = http.server.HTTPServer(("127.0.0.1",p),H)
t = threading.Timer(30, srv.shutdown); t.daemon=True; t.start()
srv.serve_forever()
PYEOF
) "$MOCK_PORT1" &
INJECT_MOCK_PID=$!

# Wait for mock
_up=0
for _i in $(seq 1 40); do
  sleep 0.1
  curl -fsS --max-time 1 "http://127.0.0.1:${MOCK_PORT1}/player/timeline/poll?commandID=0" \
    >/dev/null 2>&1 && { _up=1; break; }
done

_rc1=0
if [[ "$_up" -eq 1 ]]; then
  _g1="${ROOT}/build/cast_tl_inject_out.txt"
  mkdir -p "${ROOT}/build"
  DAEMON_BASE="http://127.0.0.1:${MOCK_PORT1}" \
    PLEX_BASE="http://127.0.0.1:${MOCK_PORT1}" \
    PLEX_TOKEN=tok CAST_FAIL_INJECT=1 CAST_CMD_ID=8000 \
    "$GATE" > "$_g1" 2>&1 || _rc1=$?
  sed 's/^/  /' "$_g1"; > "$_g1"
else
  echo "  inject-mock not up (port $MOCK_PORT1); subtest-2 covers assert path"
fi
kill "$INJECT_MOCK_PID" 2>/dev/null || true; INJECT_MOCK_PID=""

case "$_rc1" in
  1)  echo "  PASS: gate exited 1 with CAST_FAIL_INJECT=1" ;;
  77) echo "  NOTE: gate exited 77 (inject-mock not up in time)" ;;
  0)  echo "  FAIL: gate returned 0 with CAST_FAIL_INJECT=1" >&2; exit 1 ;;
  *)  echo "  FAIL: unexpected exit $_rc1 with CAST_FAIL_INJECT=1" >&2; exit 1 ;;
esac

# ── subtest 2: full mock always returning state=paused time=0 ─────────────────
echo "=== red-subtest-2: full mock state=paused time=0 ==="
MOCK_PORT2=$(pick_port 19110 19200)
echo "  mock port: $MOCK_PORT2"

# Serves state=paused/time=0 for /player/* paths; minimal PMS root for others
python3 <(cat << 'PYEOF'
import sys, http.server, threading

BROKEN = (b'<?xml version="1.0" encoding="UTF-8"?>'
          b'<MediaContainer machineIdentifier="mock-broken" size="1" commandID="1"'
          b' location="fullScreenVideo">'
          b'<Timeline type="video" state="paused" time="0" duration="1286942" /></MediaContainer>')
ROOT_XML = b'<?xml version="1.0" encoding="UTF-8"?><MediaContainer machineIdentifier="mock-broken" />'

class B(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = BROKEN if '/player' in self.path else ROOT_XML
        self.send_response(200); self.send_header("Content-Type","application/xml")
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

p = int(sys.argv[1]) if len(sys.argv)>1 else 19110
srv = http.server.HTTPServer(("127.0.0.1",p),B)
t = threading.Timer(60, srv.shutdown); t.daemon=True; t.start()
srv.serve_forever()
PYEOF
) "$MOCK_PORT2" &
MOCK_PID=$!

_up2=0
for _i in $(seq 1 40); do
  sleep 0.1
  _p=$(curl -fsS --max-time 1 \
    "http://127.0.0.1:${MOCK_PORT2}/player/timeline/poll?commandID=0" 2>/dev/null) || true
  echo "$_p" | grep -q 'state="paused"' && { _up2=1; break; }
done

if [[ "$_up2" -eq 0 ]]; then
  echo "  SKIP: mock did not start on port $MOCK_PORT2" >&2; exit 77
fi
echo "  mock serving state=paused time=0 on 127.0.0.1:${MOCK_PORT2}"

_rc2=0
_g2="${ROOT}/build/cast_tl_red_gate_out.txt"
mkdir -p "${ROOT}/build"
# DAEMON_BASE routes gate to mock; mock returns paused/0 for all timeline polls
DAEMON_BASE="http://127.0.0.1:${MOCK_PORT2}" \
  PLEX_BASE="http://127.0.0.1:${MOCK_PORT2}" \
  PLEX_TOKEN=tok-red CAST_POLL_SECONDS=6 CAST_CMD_ID=9000 \
  "$GATE" > "$_g2" 2>&1 || _rc2=$?

sed 's/^/    /' "$_g2"; > "$_g2"
kill "$MOCK_PID" 2>/dev/null || true; MOCK_PID=""

case "$_rc2" in
  1) echo "  PASS: gate exited 1 (FAIL) against broken mock — correct red" ;;
  0) echo "  FAIL: gate returned PASS against state=paused time=0 mock!" >&2; exit 1 ;;
  *) echo "  FAIL: unexpected exit $_rc2 from gate vs broken mock" >&2; exit 1 ;;
esac

echo "test_cast_timeline_poll_red: OK"
exit 0
