#!/usr/bin/env bash
# Host-only: atomic pair rollback + honest plexctl host guard.
# Never touches the real device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/rollback-honest-test"
PLEXCTL="$ROOT/scripts/plexctl.sh"
ROLLBACK="$ROOT/scripts/rollback_v2.sh"
CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
DAEMON_MD5=50f4eb925de10e29172999a565c87684
DDR_DAEMON=e9f79de217982aff44207664fdb945c5

rm -rf "$WORK"
mkdir -p "$WORK" "$WORK/pins"
chmod +x "$PLEXCTL" "$ROLLBACK" \
  "$ROOT/scripts/pair_ship_policy.sh" \
  "$ROOT/scripts/pair_visual_gate.sh"
bash -n "$PLEXCTL"
bash -n "$ROLLBACK"
bash -n "$ROOT/scripts/pair_ship_policy.sh"

# --- plexctl load_core on host ----------------------------------------------
echo "=== plexctl load_core on host must be CANNOT_CHECK, not MISSING ==="
set +e
out=$(bash "$PLEXCTL" reload-v2 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's/^/  [plexctl] /'
echo "  [plexctl] true rc=$rc"
[ "$rc" -eq 4 ] || { echo "FAIL plexctl host want rc=4 got $rc"; exit 1; }
echo "$out" | grep -q 'ERROR no core at' && { echo "FAIL false no-core"; exit 1; }
echo "$out" | grep -qE 'NOT_ON_DEVICE|cannot check device path|not on MiSTer' || {
  echo "FAIL need honest host wording"; exit 1
}
echo "OK plexctl-host-cannot-check rc=4"

# --- pair policy ------------------------------------------------------------
echo "=== pair policy accepts SPI hybrid ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check "$CORE_MD5" "$DAEMON_MD5" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] || { echo "FAIL spi pair"; exit 1; }
echo "$out" | grep -q PAIR_OK || { echo "FAIL PAIR_OK"; exit 1; }
echo "OK spi-pair"

echo "=== pair policy REFUSES spi core + ddr daemon (green screen) ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check "$CORE_MD5" "$DDR_DAEMON" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /'
[ "$rc" -eq 1 ] || { echo "FAIL want refuse rc=1 got $rc"; exit 1; }
echo "$out" | grep -qi 'spi_core_plus_ddr_daemon\|solid_green' || {
  echo "FAIL need green-screen refuse reason"; exit 1
}
echo "OK refuse-mixed-pair"

# --- fake transports --------------------------------------------------------
cat >"$WORK/fake_ssh.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${ROLLBACK_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
cmd="${1:-}"
attempt_file="${ROLLBACK_ATTEMPT_FILE:-}"

fail_n=${ssh_fail_first_n:-0}
if [[ -n "$attempt_file" ]]; then
  att=0
  [[ -f "$attempt_file" ]] && att=$(cat "$attempt_file")
  att=$((att + 1))
  echo "$att" >"$attempt_file"
  if [[ "$att" -le "$fail_n" ]]; then
    echo "No route to host" >&2
    exit 255
  fi
fi

# core md5
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"Plex_v2.rbf"* ]]; then
  if [[ "${core_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${core_state:-ok}" == "empty" ]]; then exit 0; fi
  echo "${core_md5:-dfebf2bfd08dd70b473b587dd7e81848}"
  exit 0
fi
# product core path (ddr pair)
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"/Plex.rbf"* && "$cmd" != *"Plex_v2"* ]]; then
  echo "${product_md5:-c5382bee73cecdee8220b811e529c297}"
  exit 0
fi
# daemon disk md5 at v2 path
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"misterplexd"* && "$cmd" != *"/proc/"* && "$cmd" != *"FOUND_"* ]]; then
  if [[ "${disk_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${disk_state:-ok}" == "empty" ]]; then exit 0; fi
  # install path may print md5sum after mv
  if [[ "$cmd" == *"mv -f"* ]] || [[ "$cmd" == *"staged"* ]]; then
    echo "${install_md5:-${disk_md5:-50f4eb925de10e29172999a565c87684}}"
    exit 0
  fi
  echo "${disk_md5:-50f4eb925de10e29172999a565c87684}"
  exit 0
fi

# on-device pin search
if [[ "$cmd" == *"FOUND_PATH="* ]] || [[ "$cmd" == *"misterplexd.*.bak"* ]]; then
  if [[ -n "${bak_path:-}" ]]; then
    echo "FOUND_PATH=${bak_path}"
    echo "FOUND_MD5=${bak_md5:-50f4eb925de10e29172999a565c87684}"
  else
    echo "FOUND_PATH="
    echo "FOUND_MD5="
  fi
  exit 0
fi

# live daemon probe
if [[ "$cmd" == *"N_DAEMON="* ]] || [[ "$cmd" == *"for d in /proc/"* ]]; then
  echo "N_DAEMON=${n_daemon:-${n_match:-1}}"
  echo "PIDS=${pids:-4242}"
  echo "LIVE_MD5=${live_md5:-50f4eb925de10e29172999a565c87684}"
  echo "LIVE_EXE=${live_exe:-/media/fat/misterplex_v2/bin/misterplexd}"
  echo "LIVE_PORT=${live_port:-3005}"
  echo "LIVE_CONF=${live_conf:-/media/fat/misterplex_v2/misterplex.conf}"
  echo "LIVE_ROOT=${live_root:-/media/fat/misterplex_v2}"
  exit 0
fi

# actions
if [[ "$cmd" == *plexctl* ]] || [[ "$cmd" == *stop* ]] || [[ "$cmd" == *load_core* ]] \
   || [[ "$cmd" == *CORE_LOAD* ]] || [[ "$cmd" == *for\ p\ in* ]] || [[ "$cmd" == *"MiSTer_cmd"* ]] \
   || [[ "$cmd" == *"mkdir -p"* ]] || [[ "$cmd" == *"chmod"* ]]; then
  if [[ "${action_rc:-0}" != "0" ]]; then exit "${action_rc}"; fi
  echo "mock-ok"
  echo "CORE_LOAD_ISSUED"
  echo "CORENAME=Plex"
  echo "start_rc=0"
  echo "stop_rc=0"
  if [[ "$cmd" == *"for p in"* ]]; then
    echo "/media/fat/misterplex/bin/plexctl.sh"
  fi
  # install returns md5 line
  if [[ "$cmd" == *"md5sum"* ]]; then
    echo "${install_md5:-50f4eb925de10e29172999a565c87684}"
  fi
  exit 0
fi

echo "fake_ssh unhandled: $cmd" >&2
exit 99
MOCK
chmod +x "$WORK/fake_ssh.sh"

cat >"$WORK/fake_http.sh" <<'HTTP'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${ROLLBACK_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
echo "${http_code:-200}"
HTTP
chmod +x "$WORK/fake_http.sh"

cat >"$WORK/fake_scp.sh" <<'SCP'
#!/usr/bin/env bash
exit 0
SCP
chmod +x "$WORK/fake_scp.sh"

# synthetic idle PNG via python (good mean ~40)
python3 - <<'PY'
from pathlib import Path
try:
    from PIL import Image
except ImportError:
    raise SystemExit(0)
# orange-ish chevron-ish field mean ~40
img = Image.new("RGB", (64, 64), (80, 40, 10))
Path("/home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest/build/rollback-honest-test/idle_ok.png").parent.mkdir(parents=True, exist_ok=True)
img.save("/home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest/build/rollback-honest-test/idle_ok.png")
# solid green
img2 = Image.new("RGB", (64, 64), (0, 180, 0))
img2.save("/home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest/build/rollback-honest-test/idle_green.png")
PY

run_rb() {
  local label="$1"; shift
  : >"$WORK/attempt"
  set +e
  out=$(
    ROLLBACK_SSH="$WORK/fake_ssh.sh" \
    ROLLBACK_HTTP="$WORK/fake_http.sh" \
    ROLLBACK_SCP="$WORK/fake_scp.sh" \
    ROLLBACK_SCENARIO="$WORK/scenario.env" \
    ROLLBACK_ATTEMPT_FILE="$WORK/attempt" \
    ROLLBACK_SSH_TRIES="${ROLLBACK_SSH_TRIES:-4}" \
    ROLLBACK_SSH_BACKOFF_S=0 \
    ROLLBACK_POST_START_SLEEP=0 \
    ROLLBACK_ERRFILE="$WORK/ssh.err" \
    PAIR_IDLE_PNG="${PAIR_IDLE_PNG:-$WORK/idle_ok.png}" \
    bash "$ROLLBACK" "$@" 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  [$label] |"
  echo "  [$label] true rc=$rc"
  LAST_OUT=$out
  LAST_RC=$rc
}

write_scen() { cat >"$WORK/scenario.env"; }

echo "=== preflight REFUSE when disk daemon is DDR and no artifact ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
# ensure no host pin
rm -f "$ROOT/artifacts/daemon-pins/misterplexd.50f4eb92"
unset ROLLBACK_DAEMON || true
run_rb refuse-no-daemon preflight
[ "$LAST_RC" -eq 10 ] || { echo "FAIL refuse want 10 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'ATOMIC_ROLLBACK\|Device left UNTOUCHED\|daemon half is NOT' || {
  echo "FAIL need atomic refuse message"; exit 1
}
echo "OK preflight-refuse-no-daemon rc=10"

echo "=== preflight OK when disk already SPI pin ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
run_rb pre-ok preflight
[ "$LAST_RC" -eq 0 ] || { echo "FAIL pre-ok want 0 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q PREFLIGHT_OK || { echo "FAIL PREFLIGHT_OK"; exit 1; }
echo "OK preflight-disk-pin rc=0"

echo "=== verify mixed pair (SPI core + DDR live) is MISMATCH not OK ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
ROLLBACK_REQUIRE_VISUAL=0 run_rb mixed verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL mixed want 3 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'PAIR_REFUSE|pair-compatibility|MISMATCH' || {
  echo "FAIL need pair refuse"; exit 1
}
echo "OK mixed-pair-verify rc=3"

echo "=== verify happy pair + visual ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
if [ -f "$WORK/idle_ok.png" ]; then
  PAIR_IDLE_PNG="$WORK/idle_ok.png" ROLLBACK_REQUIRE_VISUAL=1 run_rb happy-vis verify
  [ "$LAST_RC" -eq 0 ] || { echo "FAIL happy-vis want 0 got $LAST_RC"; exit 1; }
  echo "$LAST_OUT" | grep -q 'OK pair-compatibility' || { echo "FAIL pair ok"; exit 1; }
  echo "OK happy-visual rc=0"
else
  echo "SKIP happy-visual (no Pillow)"
fi

echo "=== verify without visual when required → rc=8 ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
PAIR_IDLE_PNG=/no/such.png ROLLBACK_REQUIRE_VISUAL=1 run_rb novis verify
[ "$LAST_RC" -eq 8 ] || { echo "FAIL novis want 8 got $LAST_RC"; exit 1; }
echo "OK visual-required rc=8"

echo "=== empty core hash is NO-DATA not MISMATCH ==="
write_scen <<SCEN
core_state=empty
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
ROLLBACK_REQUIRE_VISUAL=0 run_rb nodata verify
[ "$LAST_RC" -eq 4 ] || { echo "FAIL nodata want 4 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'NO-DATA core-disk' || { echo "FAIL NO-DATA"; exit 1; }
echo "OK nodata-empty rc=4"

echo "=== NETWORK after retries ==="
write_scen <<SCEN
ssh_fail_first_n=99
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_daemon=1
http_code=200
SCEN
ROLLBACK_SSH_TRIES=3 ROLLBACK_REQUIRE_VISUAL=0 run_rb netfail verify
[ "$LAST_RC" -eq 5 ] || { echo "FAIL network want 5 got $LAST_RC"; exit 1; }
echo "OK network rc=5"

echo "=== restore refuses without daemon artifact (device untouched path) ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DDR_DAEMON
live_md5=$DDR_DAEMON
n_daemon=1
http_code=200
SCEN
run_rb restore-refuse restore
[ "$LAST_RC" -eq 10 ] || { echo "FAIL restore-refuse want 10 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'UNTOUCHED\|ATOMIC_ROLLBACK' || {
  echo "FAIL need untouched"; exit 1
}
echo "OK restore-refuse-atomic rc=10"

echo "ALL test_rollback_honest checks passed"
exit 0
