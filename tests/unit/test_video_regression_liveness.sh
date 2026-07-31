#!/usr/bin/env bash
# Host-only mutation test for scripts/video_regression.sh liveness gate.
# Proves the OLD on-disk-only check PASSes while the daemon is dead (defect),
# and the NEW /proc argv0 + /proc/PID/exe + HTTP gate FAILs that case and
# PASSes the live cases. Never touches the real device — injects VIDREG_SSHM
# and VIDREG_HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/video_regression.sh"
WORK="$ROOT/build/video-regression-liveness"
BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
# Keep in lockstep with scripts/video_regression.sh pins (54f1d916 tip rebuild lineage).
HYBRID_DAEMON_MD5=54f1d9164735e04e2111565257fcf13e
PREV_HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
BIN_PATH=/media/fat/misterplex_v2/bin/misterplexd
CORE_PATH=/media/fat/_Utility/Plex_v2.rbf
V2_CONF=/media/fat/misterplex_v2/misterplex.conf

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$SCRIPT"
bash -n "$SCRIPT"

# --- OLD defective check (quoted from pre-fix video_regression.sh) -------------
# This is the behaviour that certified a dead daemon. Kept inline so the RED
# direction does not depend on git history remaining available.
old_verify_disk_only() {
  local sshm_cmd="$1"
  local got_core got_daemon rc=0
  got_core=$($sshm_cmd "md5sum $CORE_PATH 2>/dev/null | cut -d' ' -f1" || true)
  got_daemon=$($sshm_cmd "md5sum $BIN_PATH 2>/dev/null | cut -d' ' -f1" || true)
  [ "$got_core" = "$BASE_CORE_MD5" ] \
    && echo "OK   core   $got_core" \
    || { echo "FAIL core   got='$got_core' want='$BASE_CORE_MD5'"; rc=1; }
  [ "$got_daemon" = "$BASE_DAEMON_MD5" ] || [ "$got_daemon" = "$HYBRID_DAEMON_MD5" ] \
    || [ "$got_daemon" = "$PREV_HYBRID_DAEMON_MD5" ] \
    && echo "OK   daemon $got_daemon" \
    || { echo "FAIL daemon got='$got_daemon' want='$BASE_DAEMON_MD5' or '$HYBRID_DAEMON_MD5'"; rc=1; }
  return $rc
}

# --- Mock remote layer ----------------------------------------------------------
# Scenario file controls what the fake device reports.
#   disk_md5=...
#   core_md5=...
#   live_md5=...          (empty = dead)
#   n_match=0|1|2
#   appear_after=N        (attempt number when live process appears; 0 = immediate)
#   http_code=200|000|...
#   live_port=3005
#   live_conf=...
write_scenario() {
  cat >"$WORK/scenario.env" "$@"
}

make_sshm() {
  cat >"$WORK/fake_sshm.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${VIDREG_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
cmd="${1:-}"
attempt_file="${VIDREG_ATTEMPT_FILE:?}"

# Core / on-disk hash queries (remote snippet includes `| cut -d' ' -f1`).
if [[ "$cmd" == md5sum*Plex_v2.rbf* ]]; then
  echo "${core_md5:-}"
  exit 0
fi
if [[ "$cmd" == md5sum*misterplexd* ]]; then
  echo "${disk_md5:-}"
  exit 0
fi

# Live probe: remote body prints DISK_MD5=/N_MATCH=/LIVE_MD5= lines.
if [[ "$cmd" == bin=* ]] || [[ "$cmd" == *"echo \"DISK_MD5="* ]] || [[ "$cmd" == *"for d in /proc/"* ]]; then
  att=0
  if [[ -f "$attempt_file" ]]; then
    att=$(cat "$attempt_file")
  fi
  att=$((att + 1))
  echo "$att" >"$attempt_file"

  appear=${appear_after:-0}
  live_now="${live_md5:-}"
  n_now="${n_match:-0}"
  port_now="${live_port:-3005}"
  conf_now="${live_conf:-}"
  if [[ "$appear" -gt 0 && "$att" -lt "$appear" ]]; then
    live_now=""
    n_now=0
    note=no_process
    port_now=""
    conf_now=""
  else
    if [[ -z "$live_now" || "$n_now" -eq 0 ]]; then
      note=no_process
      n_now=0
      port_now=""
      conf_now=""
    elif [[ "$n_now" -gt 1 ]]; then
      note=multi_match
    else
      note=ok
    fi
  fi

  echo "DISK_MD5=${disk_md5:-}"
  echo "N_MATCH=$n_now"
  if [[ "$n_now" -eq 1 ]]; then
    echo "PIDS=4242"
  elif [[ "$n_now" -gt 1 ]]; then
    echo "PIDS=4242 4243"
  else
    echo "PIDS="
  fi
  echo "LIVE_MD5=${live_now}"
  echo "LIVE_PORT=${port_now}"
  echo "LIVE_CONF=${conf_now}"
  echo "LIVE_NOTE=$note"
  exit 0
fi

echo "fake_sshm: unhandled cmd: $cmd" >&2
exit 99
MOCK
  chmod +x "$WORK/fake_sshm.sh"

  cat >"$WORK/fake_http.sh" <<'HTTP'
#!/usr/bin/env bash
set -euo pipefail
SCEN="${VIDREG_SCENARIO:?}"
# shellcheck disable=SC1090
source "$SCEN"
# Echo the HTTP status code only (matches curl -w '%{http_code}').
echo "${http_code:-000}"
HTTP
  chmod +x "$WORK/fake_http.sh"
}

run_new_verify() {
  local label="$1"
  shift
  : >"$WORK/attempt"
  set +e
  out=$(
    VIDREG_SSHM="$WORK/fake_sshm.sh" \
    VIDREG_HTTP="$WORK/fake_http.sh" \
    VIDREG_SCENARIO="$WORK/scenario.env" \
    VIDREG_ATTEMPT_FILE="$WORK/attempt" \
    LIVE_WAIT_SEC="${LIVE_WAIT_SEC:-1}" \
    LIVE_POLL_SEC="${LIVE_POLL_SEC:-0.05}" \
    bash "$SCRIPT" verify 2>&1
  )
  rc=$?
  set -e
  printf '%s\n' "$out" | sed "s|^|  [$label] |"
  echo "  [$label] true rc=$rc"
  LAST_OUT=$out
  LAST_RC=$rc
}

expect_rc() {
  local label="$1" want="$2"
  if [[ "$LAST_RC" -ne "$want" ]]; then
    echo "FAIL $label: rc=$LAST_RC want=$want" >&2
    exit 1
  fi
  echo "OK $label rc=$LAST_RC"
}

expect_grep() {
  local label="$1" pat="$2"
  if ! grep -qE "$pat" <<<"$LAST_OUT"; then
    echo "FAIL $label: output missing /$pat/" >&2
    exit 1
  fi
  echo "OK $label grep /$pat/"
}

make_sshm

# ===========================================================================
echo "=== RED direction: OLD on-disk-only check PASSes while daemon is DEAD ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=
n_match=0
appear_after=0
http_code=000
live_port=3005
live_conf=$V2_CONF
EOF
: >"$WORK/attempt"
set +e
old_out=$(
  VIDREG_SCENARIO="$WORK/scenario.env" \
  VIDREG_ATTEMPT_FILE="$WORK/attempt" \
  old_verify_disk_only "$WORK/fake_sshm.sh" 2>&1
)
old_rc=$?
set -e
printf '%s\n' "$old_out" | sed 's|^|  [old-dead] |'
echo "  [old-dead] true rc=$old_rc"
if [[ "$old_rc" -ne 0 ]]; then
  echo "FAIL: old disk-only check must PASS (rc=0) on dead daemon + good disk hash — defect not reproduced" >&2
  exit 1
fi
echo "OK old-dead-passes rc=0 (defect reproduced)"

# ===========================================================================
echo "=== NEW gate: same dead-daemon fixture must HARD FAIL ==="
run_new_verify "new-dead"
expect_rc "new-dead" 1
expect_grep "new-dead-msg" 'FAIL daemon-live n_daemon=0'

# ===========================================================================
echo "=== NEW gate: live accepted hybrid md5 + HTTP 200 PASSes ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-live"
expect_rc "new-live" 0
expect_grep "new-live-ok" 'OK   daemon-live '"$HYBRID_DAEMON_MD5"
expect_grep "new-live-http" 'OK   daemon-http'
expect_grep "new-live-conf" 'OK   daemon-conf '"$V2_CONF"

# ===========================================================================
echo "=== NEW gate: PREV hybrid pin still accepted ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$PREV_HYBRID_DAEMON_MD5
live_md5=$PREV_HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-prev"
expect_rc "new-prev" 0
expect_grep "new-prev-ok" 'OK   daemon-live '"$PREV_HYBRID_DAEMON_MD5"

# ===========================================================================
echo "=== NEW gate: process up but HTTP dead → FAIL ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=000
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-http-dead"
expect_rc "new-http-dead" 1
expect_grep "new-http-dead-msg" 'FAIL daemon-http'

# ===========================================================================
echo "=== NEW gate: ETXTBSY — disk new, live old → FAIL with explicit hint ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$BASE_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-etxtbsy"
expect_rc "new-etxtbsy" 1
expect_grep "new-etxtbsy-mismatch" 'FAIL daemon-disk/live mismatch'
expect_grep "new-etxtbsy-hint" 'ETXTBSY'

# ===========================================================================
echo "=== NEW gate: multi-match refuses ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=2
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-multi"
expect_rc "new-multi" 1
expect_grep "new-multi-msg" 'multi-match'

# ===========================================================================
echo "=== NEW gate: brief down then respawn within wait → PASS with note ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=3
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "new-respawn"
expect_rc "new-respawn" 0
expect_grep "new-respawn-note" 'respawned during wait'

# ===========================================================================
echo "=== NEW gate: never comes back within wait → FAIL ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=
n_match=0
appear_after=0
http_code=000
live_port=3005
live_conf=$V2_CONF
EOF
LIVE_WAIT_SEC=0 LIVE_POLL_SEC=0 run_new_verify "new-timeout"
expect_rc "new-timeout" 1
expect_grep "new-timeout-msg" 'n_daemon=0'

echo "ALL test_video_regression_liveness checks passed"
exit 0
