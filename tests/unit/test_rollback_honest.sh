#!/usr/bin/env bash
# Host-only tests: rollback/plexctl must never report a false catastrophe.
# - plexctl load_core on host without /dev/MiSTer_cmd → CANNOT_CHECK (rc=4), not MISSING
# - empty remote hash → NO-DATA (rc=4), not MISMATCH
# - NETWORK after exhausted retries → rc=5
# - happy path verify → rc=0 with live md5 + HTTP
# Never touches the real device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/rollback-honest-test"
PLEXCTL="$ROOT/scripts/plexctl.sh"
ROLLBACK="$ROOT/scripts/rollback_v2.sh"
CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
DAEMON_MD5=50f4eb925de10e29172999a565c87684

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$PLEXCTL" "$ROLLBACK"
bash -n "$PLEXCTL"
bash -n "$ROLLBACK"

# --- plexctl load_core on host (no /dev/MiSTer_cmd) --------------------------------
echo "=== plexctl load_core on host must be CANNOT_CHECK, not MISSING ==="
set +e
out=$(bash "$PLEXCTL" reload-v2 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's/^/  [plexctl] /'
echo "  [plexctl] true rc=$rc"
if [ "$rc" -ne 4 ]; then
  echo "FAIL plexctl host reload-v2 want rc=4 CANNOT_CHECK got $rc" >&2
  exit 1
fi
if echo "$out" | grep -q 'ERROR no core at'; then
  echo "FAIL plexctl used false 'no core' catastrophe wording" >&2
  exit 1
fi
if ! echo "$out" | grep -qE 'NOT_ON_DEVICE|cannot check device path|NO-DATA'; then
  echo "FAIL plexctl must say NOT_ON_DEVICE / cannot check" >&2
  exit 1
fi
echo "OK plexctl-host-cannot-check rc=4"

# --- rollback mock layer ----------------------------------------------------------
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

# File md5 probes
if [[ "$cmd" == *"md5sum"* && "$cmd" == *"Plex_v2.rbf"* ]]; then
  if [[ "${core_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${core_state:-ok}" == "empty" ]]; then exit 0; fi
  echo "${core_md5:-dfebf2bfd08dd70b473b587dd7e81848}"
  exit 0
fi
if [[ "$cmd" == *"misterplexd"* && "$cmd" == *"md5sum"* ]] && [[ "$cmd" != *"/proc/"* ]]; then
  if [[ "${disk_state:-ok}" == "missing" ]]; then echo MISSING; exit 0; fi
  if [[ "${disk_state:-ok}" == "empty" ]]; then exit 0; fi
  echo "${disk_md5:-50f4eb925de10e29172999a565c87684}"
  exit 0
fi

# Live daemon probe (multi-line remote script)
if [[ "$cmd" == *"N_MATCH="* ]] || [[ "$cmd" == *"for d in /proc/"* ]] || [[ "$cmd" == bin=* ]]; then
  echo "N_MATCH=${n_match:-1}"
  echo "PIDS=${pids:-4242}"
  echo "LIVE_MD5=${live_md5:-50f4eb925de10e29172999a565c87684}"
  echo "LIVE_PORT=${live_port:-3005}"
  echo "LIVE_CONF=${live_conf:-/media/fat/misterplex_v2/misterplex.conf}"
  exit 0
fi

# stop / start / load sequences
if [[ "$cmd" == *plexctl* ]] || [[ "$cmd" == *stop* ]] || [[ "$cmd" == *load_core* ]] \
   || [[ "$cmd" == *CORE_LOAD* ]] || [[ "$cmd" == *for\ p\ in* ]] || [[ "$cmd" == *"MiSTer_cmd"* ]]; then
  if [[ "${action_rc:-0}" != "0" ]]; then exit "${action_rc}"; fi
  echo "mock-ok"
  echo "CORE_LOAD_ISSUED"
  echo "CORENAME=Plex"
  echo "start_rc=0"
  echo "stop_rc=0"
  if [[ "$cmd" == *"for p in"* ]]; then
    echo "/media/fat/misterplex/bin/plexctl.sh"
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

run_rb() {
  local label="$1"; shift
  : >"$WORK/attempt"
  set +e
  out=$(
    ROLLBACK_SSH="$WORK/fake_ssh.sh" \
    ROLLBACK_HTTP="$WORK/fake_http.sh" \
    ROLLBACK_SCENARIO="$WORK/scenario.env" \
    ROLLBACK_ATTEMPT_FILE="$WORK/attempt" \
    ROLLBACK_SSH_TRIES="${ROLLBACK_SSH_TRIES:-4}" \
    ROLLBACK_SSH_BACKOFF_S=0 \
    ROLLBACK_POST_START_SLEEP=0 \
    ROLLBACK_ERRFILE="$WORK/ssh.err" \
    bash "$ROLLBACK" "$@" 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  [$label] |"
  echo "  [$label] true rc=$rc"
  LAST_OUT=$out
  LAST_RC=$rc
}

write_scen() {
  cat >"$WORK/scenario.env"
}

echo "=== rollback verify happy path ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_match=1
http_code=200
ssh_fail_first_n=0
SCEN
run_rb happy verify
[ "$LAST_RC" -eq 0 ] || { echo "FAIL happy want 0"; exit 1; }
echo "$LAST_OUT" | grep -q 'OK core-disk' || { echo "FAIL missing OK core-disk"; exit 1; }
echo "$LAST_OUT" | grep -q 'OK daemon-live' || { echo "FAIL missing OK daemon-live"; exit 1; }
echo "$LAST_OUT" | grep -q 'OK http' || { echo "FAIL missing OK http"; exit 1; }
echo "OK happy rc=0"

echo "=== empty core hash is NO-DATA not MISMATCH ==="
write_scen <<SCEN
core_state=empty
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_match=1
http_code=200
SCEN
run_rb nodata verify
[ "$LAST_RC" -eq 4 ] || { echo "FAIL nodata want rc=4 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'NO-DATA core-disk' || { echo "FAIL need NO-DATA core-disk"; exit 1; }
if echo "$LAST_OUT" | grep -qE "MISMATCH core-disk got=''"; then
  echo "FAIL empty reported as MISMATCH"; exit 1
fi
echo "OK nodata-empty rc=4"

echo "=== MISSING core (proven on device) ==="
write_scen <<SCEN
core_state=missing
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_match=1
http_code=200
SCEN
run_rb missing verify
[ "$LAST_RC" -eq 2 ] || { echo "FAIL missing want rc=2 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'MISSING core-disk' || { echo "FAIL need MISSING"; exit 1; }
echo "OK missing rc=2"

echo "=== NETWORK after retries ==="
write_scen <<SCEN
ssh_fail_first_n=99
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_match=1
http_code=200
SCEN
ROLLBACK_SSH_TRIES=3 run_rb netfail verify
[ "$LAST_RC" -eq 5 ] || { echo "FAIL network want rc=5 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -qE 'NETWORK|ssh-FAILED' || { echo "FAIL need NETWORK marker"; exit 1; }
echo "OK network rc=5"

echo "=== SSH flaky then recovers (retry works) ==="
write_scen <<SCEN
ssh_fail_first_n=2
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=$DAEMON_MD5
n_match=1
http_code=200
SCEN
ROLLBACK_SSH_TRIES=5 run_rb flaky verify
[ "$LAST_RC" -eq 0 ] || { echo "FAIL flaky want 0 got $LAST_RC"; exit 1; }
echo "OK flaky-retry rc=0"

echo "=== disk/live ETXTBSY mismatch ==="
write_scen <<SCEN
core_md5=$CORE_MD5
disk_md5=$DAEMON_MD5
live_md5=7cd10b4d438c714a9b8c4766dc982d59
n_match=1
http_code=200
SCEN
run_rb etxt verify
[ "$LAST_RC" -eq 3 ] || { echo "FAIL etxt want 3 got $LAST_RC"; exit 1; }
echo "$LAST_OUT" | grep -q 'ETXTBSY' || { echo "FAIL need ETXTBSY hint"; exit 1; }
echo "OK etxtbsy rc=3"

echo "ALL test_rollback_honest checks passed"
exit 0
