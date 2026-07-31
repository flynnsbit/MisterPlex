#!/usr/bin/env bash
# Host-only mutation test for scripts/video_regression.sh:
#   1) OLD on-disk-only check PASSes while daemon is dead (defect reproduced)
#   2) NEW live daemon gate FAILs dead / PASSes live
#   3) RUNNING CORE claim + (core,daemon) pair coherence:
#        - missing/stale claim → FAIL (not skip)
#        - SPI core + DDR daemon → FAIL (mixed-state class)
#        - coherent SPI pair + claim → PASS
# Never touches the real device — injects VIDREG_SSHM and VIDREG_HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/video_regression.sh"
WORK="$ROOT/build/video-regression-liveness"
BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
PREV_HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7
DDR_CORE_PREFIX=c5382bee
DDR_DAEMON_PREFIX=e9f79de2
DDR_CORE_MD5="${DDR_CORE_PREFIX}aaaaaaaaaaaaaaaaaaaaaaaa"
DDR_DAEMON_MD5="${DDR_DAEMON_PREFIX}bbbbbbbbbbbbbbbbbbbbbbbb"
BIN_PATH=/media/fat/misterplex_v2/bin/misterplexd
CORE_PATH=/media/fat/_Utility/Plex_v2.rbf
V2_CONF=/media/fat/misterplex_v2/misterplex.conf

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$SCRIPT"
bash -n "$SCRIPT"

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
    || { echo "FAIL daemon got='$got_daemon'"; rc=1; }
  return $rc
}

write_scenario() {
  cat >"$WORK/scenario.env"
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

if [[ "$cmd" == md5sum*Plex_v2.rbf* ]]; then
  echo "${core_md5:-}"
  exit 0
fi
if [[ "$cmd" == md5sum*Plex.rbf* ]]; then
  echo "${dev_core_md5:-}"
  exit 0
fi
if [[ "$cmd" == md5sum*misterplexd* ]]; then
  echo "${disk_md5:-}"
  exit 0
fi

if [[ "$cmd" == CLAIM_PATH=* ]] || [[ "$cmd" == *"RBFNAME_MTIME"* ]] || [[ "$cmd" == *"echo \"CORENAME="* ]]; then
  echo "CORENAME=${corename:-Plex}"
  echo "RBFNAME=${rbfname:-Plex}"
  echo "RBFNAME_MTIME=${rbfname_mtime:-1000}"
  echo "DISK_V2_MD5=${core_md5:-}"
  echo "DISK_DEV_MD5=${dev_core_md5:-}"
  echo "CLAIM_PRESENT=${claim_present:-0}"
  echo "CLAIM_MD5=${claim_md5:-}"
  echo "CLAIM_PATH_FIELD=${claim_path_field:-}"
  echo "CLAIM_RBFNAME_MTIME=${claim_rbfname_mtime:-}"
  echo "CLAIM_SOURCE=${claim_source:-}"
  echo "FPGA_MGR_STATE=${fpga_mgr_state:-}"
  echo "PLXK_WORD=${plxk_word:-}"
  echo "PLXS_WORD=${plxs_word:-}"
  echo "PLXD_WORD=${plxd_word:-}"
  echo "PLXC_WORD=${plxc_word:-}"
  exit 0
fi

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
echo "${http_code:-000}"
HTTP
  chmod +x "$WORK/fake_http.sh"
}

run_new_verify() {
  local label="$1"
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
    printf '%s\n' "$LAST_OUT" | tail -n 40 >&2
    exit 1
  fi
  echo "OK $label grep /$pat/"
}

spi_claim_ok() {
  cat <<EOF
claim_present=1
claim_md5=$BASE_CORE_MD5
claim_path_field=$CORE_PATH
claim_rbfname_mtime=1000
claim_source=test
rbfname_mtime=1000
corename=Plex
rbfname=Plex
EOF
}

make_sshm

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
$(spi_claim_ok)
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
  echo "FAIL: old disk-only check must PASS (rc=0) on dead daemon — defect not reproduced" >&2
  exit 1
fi
echo "OK old-dead-passes rc=0 (defect reproduced)"

echo "=== NEW gate: dead daemon + good claim must HARD FAIL ==="
run_new_verify "new-dead"
expect_rc "new-dead" 1
expect_grep "new-dead-msg" 'FAIL daemon-live n_daemon=0'

echo "=== NEW gate: missing running-core claim → FAIL (not skip) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
claim_present=0
claim_md5=
claim_path_field=
claim_rbfname_mtime=
rbfname_mtime=1000
corename=Plex
rbfname=Plex
EOF
run_new_verify "no-claim"
expect_rc "no-claim" 1
expect_grep "no-claim-msg" 'FAIL running-core: no verified load claim'
expect_grep "no-claim-not-skip" 'cannot soft-skip unknown fabric'

echo "=== NEW gate: stale claim (mtime drift) → FAIL ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
claim_present=1
claim_md5=$BASE_CORE_MD5
claim_path_field=$CORE_PATH
claim_rbfname_mtime=1000
claim_source=stale
rbfname_mtime=2000
corename=Plex
rbfname=Plex
EOF
run_new_verify "stale-claim"
expect_rc "stale-claim" 1
expect_grep "stale-claim-msg" 'claim stale'

echo "=== NEW gate: SPI core claim + DDR daemon live → FAIL pair-mismatch ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
$(spi_claim_ok)
EOF
run_new_verify "mixed-spi-core-ddr-daemon"
expect_rc "mixed-spi-core-ddr-daemon" 1
expect_grep "mixed-msg" 'FAIL pair-mismatch'
expect_grep "mixed-hint" 'SPI/DDR mix'

echo "=== NEW gate: DDR core claim + SPI hybrid daemon → FAIL pair-mismatch ==="
write_scenario <<EOF
core_md5=$DDR_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
claim_present=1
claim_md5=$DDR_CORE_MD5
claim_path_field=/media/fat/_Utility/Plex.rbf
claim_rbfname_mtime=1000
claim_source=test
rbfname_mtime=1000
dev_core_md5=$DDR_CORE_MD5
corename=Plex
rbfname=Plex
EOF
run_new_verify "mixed-ddr-core-spi-daemon"
expect_rc "mixed-ddr-core-spi-daemon" 1
expect_grep "mixed2-msg" 'FAIL pair-mismatch|FAIL core-running'

echo "=== NEW gate: coherent SPI hybrid + claim + HTTP 200 PASSes ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$HYBRID_DAEMON_MD5
live_md5=$HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
$(spi_claim_ok)
EOF
run_new_verify "new-live"
expect_rc "new-live" 0
expect_grep "new-live-core" "OK   core-running $BASE_CORE_MD5"
expect_grep "new-live-ok" "OK   daemon-live $HYBRID_DAEMON_MD5"
expect_grep "new-live-http" 'OK   daemon-http'
expect_grep "new-live-pair" 'OK   pair-coherent'
expect_grep "new-live-conf" "OK   daemon-conf $V2_CONF"

echo "=== NEW gate: coherent DDR pair (c5382bee + e9f79de2) PASSes ==="
write_scenario <<EOF
core_md5=$DDR_CORE_MD5
disk_md5=$DDR_DAEMON_MD5
live_md5=$DDR_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
claim_present=1
claim_md5=$DDR_CORE_MD5
claim_path_field=/media/fat/_Utility/Plex.rbf
claim_rbfname_mtime=1000
claim_source=test
rbfname_mtime=1000
dev_core_md5=$DDR_CORE_MD5
corename=Plex
rbfname=Plex
EOF
run_new_verify "ddr-pair"
expect_rc "ddr-pair" 0
expect_grep "ddr-pair-core" "OK   core-running $DDR_CORE_MD5"
expect_grep "ddr-pair-ok" 'OK   pair-coherent'
expect_grep "ddr-family" 'family=ddr'

echo "=== NEW gate: PREV hybrid pin still accepted (coherent SPI) ==="
write_scenario <<EOF
core_md5=$BASE_CORE_MD5
disk_md5=$PREV_HYBRID_DAEMON_MD5
live_md5=$PREV_HYBRID_DAEMON_MD5
n_match=1
appear_after=0
http_code=200
live_port=3005
live_conf=$V2_CONF
$(spi_claim_ok)
EOF
run_new_verify "new-prev"
expect_rc "new-prev" 0
expect_grep "new-prev-ok" "OK   daemon-live $PREV_HYBRID_DAEMON_MD5"

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
$(spi_claim_ok)
EOF
run_new_verify "new-http-dead"
expect_rc "new-http-dead" 1
expect_grep "new-http-dead-msg" 'FAIL daemon-http'

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
$(spi_claim_ok)
EOF
run_new_verify "new-etxtbsy"
expect_rc "new-etxtbsy" 1
expect_grep "new-etxtbsy-mismatch" 'FAIL daemon-disk/live mismatch'
expect_grep "new-etxtbsy-hint" 'ETXTBSY'

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
$(spi_claim_ok)
EOF
run_new_verify "new-multi"
expect_rc "new-multi" 1
expect_grep "new-multi-msg" 'multi-match'

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
$(spi_claim_ok)
EOF
run_new_verify "new-respawn"
expect_rc "new-respawn" 0
expect_grep "new-respawn-note" 'respawned during wait'

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
$(spi_claim_ok)
EOF
LIVE_WAIT_SEC=0 LIVE_POLL_SEC=0 run_new_verify "new-timeout"
expect_rc "new-timeout" 1
expect_grep "new-timeout-msg" 'n_daemon=0'

echo "ALL test_video_regression_liveness checks passed"
exit 0
