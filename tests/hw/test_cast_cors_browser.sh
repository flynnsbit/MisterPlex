#!/usr/bin/env bash
# Cast CORS gate — hermetic, no MiSTer and no PMS required.
#
# The user-visible defect: MiSTerPlex appears in Plex Web's cast list but
# pressing play does nothing and the web player stays at 0:00. Measured cause:
# Plex Web 4.160.0 attaches X-Plex-Target-Client-Identifier to every /player/
# request; the companion's CORS preflight did not allow that header, so Chrome
# refused to send playMedia or timeline polls at all. The cast list itself comes
# from PMS /clients (server-side, no CORS), which is why the device still looked
# available.
#
# This gate runs a real Chromium with web security ENABLED against a locally
# started misterplexd, from a cross-origin page.
#
# Exit codes: 0 pass, 1 fail, 2 refuse (setup impossible), 77 skip (no browser).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE="$ROOT/tests/hw/e2e/cast_cors_browser.js"

# Header sets, measured from the Plex Web bundle (main-*-plex-4.160.0-*.js):
#   headers:{"X-Plex-Target-Client-Identifier": n.get("machineIdentifier")}
# is attached by the shared /player/ command helper.
PLEX_WEB_HEADERS="X-Plex-Client-Identifier,X-Plex-Token,X-Plex-Target-Client-Identifier"
# Control set: identical minus the one header under test.
CONTROL_HEADERS="X-Plex-Client-Identifier,X-Plex-Token"

refuse() { echo "CAST_CORS_GATE_REFUSE: $*" >&2; exit 2; }
fail()   { echo "CAST_CORS_GATE_FAIL: $*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || refuse "node not available"
[ -f "$PROBE" ] || refuse "probe script missing: $PROBE"

free_port() {
  python3 - "$1" <<'PY'
import socket, sys
start = int(sys.argv[1])
for p in range(start, start + 200):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", p)); print(p); s.close(); break
    except OSError:
        s.close()
else:
    raise SystemExit(1)
PY
}

make -C "$ROOT" plexd >/dev/null 2>&1 || refuse "misterplexd build failed"
BIN="$ROOT/build/misterplexd"
[ -x "$BIN" ] || refuse "misterplexd binary missing"

DAEMON_PORT="$(free_port 13400)" || refuse "no free daemon port"
ORIGIN_PORT="$(free_port 13600)" || refuse "no free origin port"
LEGACY_PORT="$(free_port 13800)" || refuse "no free legacy-server port"
[ -n "$DAEMON_PORT" ] && [ -n "$ORIGIN_PORT" ] && [ -n "$LEGACY_PORT" ] || refuse "port allocation failed"

WORK="$ROOT/build/cast_cors"
mkdir -p "$WORK/origin"
printf '<!doctype html><title>cast cors origin</title>\n' > "$WORK/origin/index.html"

# Legacy companion stand-in: replays the exact pre-fix preflight response so the
# gate can prove a real browser rejects it. Without this the "green" run would
# only prove the browser can talk to *some* server, not that it detects the bug.
cat > "$WORK/legacy_cors_server.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LEGACY_ALLOW = ("X-Plex-Token, X-Plex-Client-Identifier, X-Plex-Product, "
                "X-Plex-Version, X-Plex-Device, X-Plex-Device-Name, "
                "X-Plex-Platform, Content-Type, Accept")
BODY = b'<?xml version="1.0" encoding="UTF-8"?><MediaContainer size="1"><Timeline type="video" state="stopped" time="0"/></MediaContainer>'

class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", LEGACY_ALLOW)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
    def do_OPTIONS(self):
        self.send_response(200); self._cors()
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        self.send_response(200); self._cors()
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(BODY))); self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

DAEMON_PID=""; ORIGIN_PID=""; LEGACY_PID=""
cleanup() {
  for p in "$DAEMON_PID" "$ORIGIN_PID" "$LEGACY_PID"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  wait 2>/dev/null
}
trap cleanup EXIT

"$BIN" --name MiSTerPlexCorsGate --id misterplex-cors-gate --port "$DAEMON_PORT" \
  > "$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
( cd "$WORK/origin" && python3 -m http.server "$ORIGIN_PORT" --bind 127.0.0.1 ) \
  > "$WORK/origin.log" 2>&1 &
ORIGIN_PID=$!
python3 "$WORK/legacy_cors_server.py" "$LEGACY_PORT" > "$WORK/legacy.log" 2>&1 &
LEGACY_PID=$!

wait_up() {
  local url="$1" i
  for i in $(seq 1 80); do
    curl -fsS -m 2 "$url" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}
wait_up "http://127.0.0.1:${DAEMON_PORT}/resources" || refuse "companion did not come up on :$DAEMON_PORT"
wait_up "http://127.0.0.1:${ORIGIN_PORT}/index.html" || refuse "origin server did not come up on :$ORIGIN_PORT"
wait_up "http://127.0.0.1:${LEGACY_PORT}/player/timeline/poll" || refuse "legacy server did not come up on :$LEGACY_PORT"

ORIGIN_URL="http://127.0.0.1:${ORIGIN_PORT}/index.html"
DAEMON_URL="http://127.0.0.1:${DAEMON_PORT}"
LEGACY_URL="http://127.0.0.1:${LEGACY_PORT}"

echo "Scope: real Chromium (web security ENABLED) cross-origin fetch of /player/timeline/poll;"
echo "       4 cases over 2 servers x 2 header sets; proves preflight allow-list, not playback."

run_case() {
  local label="$1" origin="$2" daemon="$3" hdrs="$4" expect="$5"
  local out rc
  out="$(node "$PROBE" "$origin" "$daemon" "$hdrs" "$expect" 2>&1)"
  rc=$?
  echo "$out" | sed "s/^/  [$label] /"
  return $rc
}

# ── Case 1 (RED CONTROL): legacy allow-list + Plex Web headers must be BLOCKED.
# If this ever "passes as allowed" the gate has lost its ability to see the bug.
run_case red-legacy-plexweb "$ORIGIN_URL" "$LEGACY_URL" "$PLEX_WEB_HEADERS" expect-block
rc=$?
case $rc in
  0) ;;
  77) echo "CAST_CORS_GATE_SKIP: browser unavailable" >&2; exit 77 ;;
  2) refuse "probe refused during red control" ;;
  *) fail "red control did not reproduce the CORS block against the legacy allow-list" ;;
esac

# ── Case 2 (RED CONTROL ISOLATION): same legacy server, header removed → allowed.
# Establishes that the block in case 1 is caused by the header under test and not
# by the legacy server, the origin, or the browser being unable to reach it.
run_case red-legacy-control "$ORIGIN_URL" "$LEGACY_URL" "$CONTROL_HEADERS" expect-allow
[ $? -eq 0 ] || fail "legacy server rejected even the control header set — comparison is not isolating the header"

# ── Case 3 (GREEN): product companion + control headers → allowed (baseline).
run_case green-control "$ORIGIN_URL" "$DAEMON_URL" "$CONTROL_HEADERS" expect-allow
[ $? -eq 0 ] || fail "companion blocked the baseline header set"

# ── Case 4 (GREEN, the product claim): product companion + real Plex Web headers.
run_case green-plexweb "$ORIGIN_URL" "$DAEMON_URL" "$PLEX_WEB_HEADERS" expect-allow
[ $? -eq 0 ] || fail "companion preflight still blocks Plex Web's X-Plex-Target-Client-Identifier"

echo "CAST_CORS_GATE_OK companion=:$DAEMON_PORT origin=:$ORIGIN_PORT legacy=:$LEGACY_PORT cases=4/4"
exit 0
