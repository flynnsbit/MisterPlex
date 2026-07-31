#!/usr/bin/env bash
# Host-only mutation test for scripts/video_regression.sh liveness gate.
# Proves the OLD on-disk-only check PASSes while the daemon is dead (defect),
# and the NEW /proc argv0 + /proc/PID/exe + HTTP gate FAILs that case and
# PASSes the live cases for BOTH known-good pairs:
#   SPI: core dfebf2bf + daemon 50f4eb92 (PREV 3e2cbb98 still accepted)
#   DDR: core c5382bee + daemon e9f79de2 (rollback core-v2 must stay intact)
# Red-before-green is proven in BOTH directions (wrong SPI, wrong DDR).
# Never touches the real device — injects VIDREG_SSHM and VIDREG_HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/video_regression.sh"
WORK="$ROOT/build/video-regression-liveness"
# Keep in lockstep with scripts/video_regression.sh pins.
BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
DDR_CORE_MD5=c5382bee73cecdee8220b811e529c297
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
PREV_HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7
DDR_DAEMON_MD5=e9f79de217982aff44207664fdb945c5
BIN_PATH=/media/fat/misterplex_v2/bin/misterplexd
CORE_PATH=/media/fat/_Utility/Plex_v2.rbf
V2_CONF=/media/fat/misterplex_v2/misterplex.conf
UNKNOWN_MD5=0123456789abcdef0123456789abcdef

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$SCRIPT"
bash -n "$SCRIPT"

# Pin lockstep: test constants must match the script under test.
for name in BASE_CORE_MD5 DDR_CORE_MD5 BASE_DAEMON_MD5 HYBRID_DAEMON_MD5 \
            PREV_HYBRID_DAEMON_MD5 DDR_DAEMON_MD5; do
  script_val=$(sed -n "s/^${name}=//p" "$SCRIPT" | head -1)
  test_val=${!name}
  if [[ "$script_val" != "$test_val" ]]; then
    echo "FAIL pin lockstep: $name script='$script_val' test='$test_val'" >&2
    exit 1
  fi
done
echo "OK pin lockstep with video_regression.sh"

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
#   core_md5=...          (Plex_v2.rbf rollback slot)
#   core_ddr_md5=...      (Plex.rbf product slot; empty = absent)
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
# Prefer Plex_v2 before bare Plex.rbf (v2 path contains the substring Plex).
if [[ "$cmd" == md5sum*Plex_v2.rbf* ]]; then
  echo "${core_md5:-}"
  exit 0
fi
if [[ "$cmd" == md5sum*Plex.rbf* ]]; then
  echo "${core_ddr_md5:-}"
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
    VIDREG_CORE_ID="${VIDREG_CORE_ID-}" \
    VIDREG_REQUIRE_CORE_ID="${VIDREG_REQUIRE_CORE_ID:-0}" \
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
core_ddr_md5=
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
echo "=== NEW gate: SPI pair (dfebf2bf + 50f4eb92) + HTTP 200 PASSes ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "spi-live"
expect_rc "spi-live" 0
expect_grep "spi-live-ok" 'OK   daemon-live '"$HYBRID_DAEMON_MD5"
expect_grep "spi-live-http" 'OK   daemon-http'
expect_grep "spi-live-conf" 'OK   daemon-conf '"$V2_CONF"
expect_grep "spi-live-pair" 'OK   pair SPI'

# ===========================================================================
echo "=== NEW gate: PREV hybrid pin still accepted (SPI pair) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=
disk_md5=$PREV_HYBRID_DAEMON_MD5
live_md5=$PREV_HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "spi-prev"
expect_rc "spi-prev" 0
expect_grep "spi-prev-ok" 'OK   daemon-live '"$PREV_HYBRID_DAEMON_MD5"
expect_grep "spi-prev-pair" 'OK   pair SPI'

# ===========================================================================
echo "=== NEW gate: DDR pair (c5382bee + e9f79de2) + rollback intact PASSes ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$DDR_CORE_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "ddr-live"
expect_rc "ddr-live" 0
expect_grep "ddr-live-ok" 'OK   daemon-live '"$DDR_DAEMON_MD5"
expect_grep "ddr-live-pair" 'OK   pair DDR'
expect_grep "ddr-live-v2" 'OK   core-v2 \(rollback\) '"$BASE_CORE_MD5"
expect_grep "ddr-live-product" 'OK   core-ddr \(product\) '"$DDR_CORE_MD5"

# ===========================================================================
echo "=== RED: DDR daemon without product core must FAIL (not silent SPI) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "ddr-no-product"
expect_rc "ddr-no-product" 1
expect_grep "ddr-no-product-msg" 'FAIL pair DDR'

# ===========================================================================
echo "=== RED: SPI daemon with wrong rollback core must FAIL ==="
write_scenario <<EOF
core_md5=$UNKNOWN_MD5
core_ddr_md5=
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "spi-bad-core"
expect_rc "spi-bad-core" 1
expect_grep "spi-bad-core-msg" 'FAIL core-v2'

# ===========================================================================
echo "=== RED: unknown product core md5 must FAIL (not accept as DDR) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$UNKNOWN_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "ddr-bad-product"
expect_rc "ddr-bad-product" 1
expect_grep "ddr-bad-product-core" 'FAIL core-ddr'
expect_grep "ddr-bad-product-pair" 'FAIL pair DDR'

# ===========================================================================
echo "=== RED: unknown daemon md5 must FAIL both directions ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$DDR_CORE_MD5
disk_md5=$UNKNOWN_MD5
live_md5=$UNKNOWN_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
run_new_verify "unknown-daemon"
expect_rc "unknown-daemon" 1
expect_grep "unknown-daemon-msg" 'FAIL daemon-live md5='

# ===========================================================================
echo "=== NEW gate: process up but HTTP dead → FAIL ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=
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
core_ddr_md5=
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
core_ddr_md5=
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
core_ddr_md5=
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
core_ddr_md5=
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

# ===========================================================================
echo "=== NEW gate: core-id RED SPI daemon + live CAP_DDR (mixed black-screen) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$DDR_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
VIDREG_CORE_ID=ddr run_new_verify "coreid-spi-on-ddr"
expect_rc "coreid-spi-on-ddr" 1
expect_grep "coreid-spi-on-ddr-msg" 'RED_SPI_DAEMON_DDR_CORE'

# ===========================================================================
echo "=== NEW gate: core-id GREEN SPI daemon + absent PLXC ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
EOF
VIDREG_CORE_ID=absent run_new_verify "coreid-spi-absent"
expect_rc "coreid-spi-absent" 0
expect_grep "coreid-spi-absent-ok" 'compatible with SPI pair'

# ===========================================================================
echo "=== NEW gate: core-id GREEN DDR daemon + CAP_DDR ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$DDR_CORE_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=/media/fat/misterplex/misterplex.conf
EOF
VIDREG_CORE_ID=ddr run_new_verify "coreid-ddr-ok"
expect_rc "coreid-ddr-ok" 0
expect_grep "coreid-ddr-ok-msg" 'path=ddr compatible with DDR pair'

# ===========================================================================
echo "=== NEW gate: core-id RED DDR daemon + require identity but absent ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
core_ddr_md5=$DDR_CORE_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=/media/fat/misterplex/misterplex.conf
EOF
VIDREG_CORE_ID=absent VIDREG_REQUIRE_CORE_ID=1 run_new_verify "coreid-ddr-require"
expect_rc "coreid-ddr-require" 1
expect_grep "coreid-ddr-require-msg" 'VIDREG_REQUIRE_CORE_ID=1'

echo "ALL test_video_regression_liveness checks passed"
exit 0
