#!/usr/bin/env bash
# mister_soft_bounce.sh — mandatory MiSTer claim + visible soft bounce.
#
# Any agent that needs to observe or drive the lab MiSTer must run this first so
# the user SEEING Menu → Plex knows the device was taken. Never silently SSH.
#
# Usage:
#   ./scripts/mister_soft_bounce.sh claim  --reason "why" [--agent ID] [-- cmd...]
#   ./scripts/mister_soft_bounce.sh release
#   ./scripts/mister_soft_bounce.sh status
#
# claim acquires an exclusive lock, soft-bounces Menu→Plex (visible), runs an
# optional command (or holds until signal), then on EXIT always releases the
# lock FIRST and soft-bounces back to Plex so the device is usable again.
#
# Env:
#   MISTER_HOST              default 192.168.1.183
#   MISTER_PASS              default 1
#   MISTER_USER              default root
#   MISTER_CLAIM_LOCK        lock dir (default: <repo>/build/mister-claim.lock)
#   MISTER_CLAIM_LOG         local audit log (default: <repo>/build/mister-claim-audit.log)
#   MISTER_CLAIM_REMOTE_LOG  device audit log (default: /media/fat/misterplex/claim-audit.log)
#   MISTER_CLAIM_TRACE       progress trace log (default: <repo>/build/mister-claim-trace.log)
#   MISTER_CLAIM_STALE_S     stale lock age seconds (default: 7200)
#   MISTER_CLAIM_FORCE=1     break a held/stale lock (documented override)
#   MISTER_CLAIM_AGENT       agent id (default: user@host-pid)
#   MISTER_CLAIM_REASON      reason string
#   MISTER_CLAIM_SKIP_BOUNCE=1
#                            local-only: exercise lock/audit without touching device
#   MISTER_CLAIM_FAKE_CORENAME
#                            unit-test inject for post-bounce CORENAME check
#                            (SKIP_BOUNCE path only; never used on a live device)
#   MISTER_CLAIM_HOLD_S      hold seconds when no command given (default: infinity)
#   MISTER_CLAIM_TEST_BOUNCE_SLEEP_S
#                            unit-test only (SKIP_BOUNCE): sleep N seconds inside
#                            soft_bounce so a mid-bounce kill can prove trap release
#   MISTER_CLAIM_RECOVER     none (default) | reboot
#                            opt-in bounded recovery when CORENAME_NOT_PLEX:
#                            soft reboot + deploy Menu→Plex (DEPLOY_SKIP_COPY=1)
#   MISTER_CLAIM_RECOVER_TIMEOUT_S  wall clock for recover path (default 180)
#   SSH_TIMEOUT_S            per-ssh wall clock (default 45)
#   BOUNCE_TIMEOUT_S         whole soft_bounce wall clock (default 120)
#   CLEANUP_TIMEOUT_S        cleanup restore bounce wall clock (default 90)
#   MISTERPLEX_ID            daemon --id after bounce (default misterplex-dev)
#   DEPLOY_WAIT_S            settle window forwarded to deploy bounce (default 5)
#
# Bounce mechanism (do not invent another):
#   DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh
# which is the Menu → wait → Plex path in deploy_plex_core.sh. Never flashes a
# different RBF (SKIP_COPY). Never thrash load_core; never kill -9 from here.
# Recovery (opt-in) also only calls deploy_plex_core.sh — never /dev/MiSTer_cmd.
#
# Post-bounce required check:
#   Read /tmp/CORENAME (banner-filtered). Must match Plex (case-insensitive).
#   If not Plex — LOUD fail (rc=5). With MISTER_CLAIM_RECOVER=reboot, attempt
#   one bounded recover then re-check; still rc=5 on failure.
#
# After successful bounce: ensure_daemon (--id $MISTERPLEX_ID). deploy_plex_core
# kills misterplexd and does not restart it.
#
# Does NOT edit /media/fat/misterplex/misterplex.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
LOCK_DIR="${MISTER_CLAIM_LOCK:-$ROOT/build/mister-claim.lock}"
LOCAL_LOG="${MISTER_CLAIM_LOG:-$ROOT/build/mister-claim-audit.log}"
REMOTE_LOG="${MISTER_CLAIM_REMOTE_LOG:-/media/fat/misterplex/claim-audit.log}"
TRACE_LOG="${MISTER_CLAIM_TRACE:-$ROOT/build/mister-claim-trace.log}"
STALE_S="${MISTER_CLAIM_STALE_S:-7200}"
FORCE="${MISTER_CLAIM_FORCE:-0}"
SKIP_BOUNCE="${MISTER_CLAIM_SKIP_BOUNCE:-0}"
HOLD_S="${MISTER_CLAIM_HOLD_S:-}"
AGENT_ID="${MISTER_CLAIM_AGENT:-}"
REASON="${MISTER_CLAIM_REASON:-}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"
SSH_TIMEOUT_S="${SSH_TIMEOUT_S:-45}"
BOUNCE_TIMEOUT_S="${BOUNCE_TIMEOUT_S:-120}"
CLEANUP_TIMEOUT_S="${CLEANUP_TIMEOUT_S:-90}"
RECOVER_MODE="${MISTER_CLAIM_RECOVER:-none}"
RECOVER_TIMEOUT_S="${MISTER_CLAIM_RECOVER_TIMEOUT_S:-180}"
MISTERPLEX_ID="${MISTERPLEX_ID:-misterplex-dev}"
TEST_BOUNCE_SLEEP_S="${MISTER_CLAIM_TEST_BOUNCE_SLEEP_S:-0}"

CMD="${1:-}"
shift || true

usage() {
  sed -n '2,55p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="${2:-}"; shift 2 ;;
    --agent) AGENT_ID="${2:-}"; shift 2 ;;
    --hold-s) HOLD_S="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-bounce) SKIP_BOUNCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [[ -z "$AGENT_ID" ]]; then
  AGENT_ID="${USER_NAME:-${USER:-agent}}@$(hostname -s 2>/dev/null || echo host)-$$"
fi
if [[ -z "$REASON" ]]; then
  REASON="unspecified"
fi

ts_iso() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

# Loud per-step progress to stdout + durable trace log.
step() {
  local msg="$*"
  local line
  line="$(printf '%s step=%s agent=%s pid=%s' "$(ts_iso)" "$msg" "$AGENT_ID" "$$")"
  printf '%s\n' "$line"
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$TRACE_LOG" 2>/dev/null || true
}

die_timeout() {
  local step_name="$1"
  local limit_s="$2"
  echo "mister_soft_bounce: TIMEOUT step=$step_name after ${limit_s}s — releasing lock and aborting" >&2
  step "timeout:$step_name limit_s=$limit_s"
  audit_local "timeout:$step_name" "limit_s=$limit_s"
  return 124
}

# Filter OpenSSH post-quantum warning banners (bug 19dde00) before any parse.
# Every ssh is wall-clock bounded: timeout --foreground -k 5 $SSH_TIMEOUT_S.
# NOTE: do NOT set BatchMode=yes — it disables password prompts and breaks
# sshpass password auth (measured: Permission denied publickey,password).
ssh_raw() {
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "mister_soft_bounce: sshpass required for device ops" >&2
    return 127
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    echo "mister_soft_bounce: GNU timeout required for bounded ssh" >&2
    return 127
  fi
  # shellcheck disable=SC2029
  timeout --foreground -k 5 "$SSH_TIMEOUT_S" \
    sshpass -p "$PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=12 \
      -o ServerAliveInterval=3 \
      -o ServerAliveCountMax=3 \
      -o NumberOfPasswordPrompts=1 \
      "$USER@$HOST" "$@"
}

ssh_clean() {
  # stdout only; strip known banner fragments if they ever land on stdout
  local out rc=0
  set +e
  out="$(ssh_raw "$@" 2>/dev/null)"
  rc=$?
  set -e
  if [[ "$rc" -eq 124 ]]; then
    die_timeout "ssh_clean" "$SSH_TIMEOUT_S"
    return 124
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: ssh_clean failed rc=$rc" >&2
    step "ssh_clean_fail rc=$rc"
    return "$rc"
  fi
  printf '%s\n' "$out" | grep -Ev 'post-quantum|OpenSSH_[0-9]|WARNING:|^\*\*\*|Permanently added' || true
  return 0
}

audit_local() {
  local event="$1"
  local extra="${2:-}"
  mkdir -p "$(dirname "$LOCAL_LOG")"
  printf '%s event=%s agent=%s pid=%s host=%s reason=%s lock=%s%s\n' \
    "$(ts_iso)" "$event" "$AGENT_ID" "$$" "$HOST" "$REASON" "$LOCK_DIR" \
    "${extra:+ $extra}" >>"$LOCAL_LOG"
}

audit_remote() {
  local event="$1"
  local extra="${2:-}"
  [[ "$SKIP_BOUNCE" == "1" ]] && return 0
  local line
  line="$(printf '%s event=%s agent=%s pid=%s host=%s reason=%s%s' \
    "$(ts_iso)" "$event" "$AGENT_ID" "$$" "$HOST" "$REASON" \
    "${extra:+ $extra}")"
  set +e
  ssh_raw "mkdir -p /media/fat/misterplex && printf '%s\n' $(printf '%q' "$line") >>$(printf '%q' "$REMOTE_LOG")" \
    >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: WARN remote audit append failed rc=$rc (local audit still written)" >&2
  fi
  return 0
}

audit() {
  local event="$1"
  local extra="${2:-}"
  audit_local "$event" "$extra"
  audit_remote "$event" "$extra"
}

lock_owner_alive() {
  local pid=""
  [[ -f "$LOCK_DIR/pid" ]] || return 1
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

lock_age_s() {
  local ts=0 now
  now="$(date +%s)"
  if [[ -f "$LOCK_DIR/timestamp_epoch" ]]; then
    ts="$(cat "$LOCK_DIR/timestamp_epoch" 2>/dev/null || echo 0)"
  elif [[ -f "$LOCK_DIR/timestamp" ]]; then
    ts="$(date -d "$(cat "$LOCK_DIR/timestamp")" +%s 2>/dev/null || echo 0)"
  fi
  if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
    echo $(( now - ts ))
  else
    echo 0
  fi
}

print_lock_status() {
  if [[ ! -d "$LOCK_DIR" ]]; then
    echo "CLAIM_FREE lock=$LOCK_DIR"
    return 0
  fi
  local age pid agent ts reason
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')"
  agent="$(cat "$LOCK_DIR/agent" 2>/dev/null || echo '?')"
  ts="$(cat "$LOCK_DIR/timestamp" 2>/dev/null || echo '?')"
  reason="$(cat "$LOCK_DIR/reason" 2>/dev/null || echo '?')"
  age="$(lock_age_s)"
  local alive=no
  lock_owner_alive && alive=yes
  echo "CLAIM_HELD lock=$LOCK_DIR agent=$agent pid=$pid alive=$alive age_s=$age ts=$ts reason=$reason"
}

break_lock_if_allowed() {
  [[ -d "$LOCK_DIR" ]] || return 0
  local age stale=0
  age="$(lock_age_s)"
  if ! lock_owner_alive; then
    if (( age >= STALE_S )) || [[ "$FORCE" == "1" ]]; then
      stale=1
    fi
  elif [[ "$FORCE" == "1" ]]; then
    stale=1
  fi
  if [[ "$stale" != "1" ]]; then
    return 1
  fi
  echo "mister_soft_bounce: breaking lock (force=$FORCE age_s=$age stale_s=$STALE_S)" >&2
  audit_local "lock_break"
  rm -rf "$LOCK_DIR"
  return 0
}

acquire_lock() {
  step "lock_acquire_begin"
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    :
  else
    if break_lock_if_allowed; then
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        print_lock_status >&2
        echo "mister_soft_bounce: CLAIM_BUSY after break attempt" >&2
        step "lock_acquire_busy"
        return 2
      fi
    else
      print_lock_status >&2
      echo "mister_soft_bounce: CLAIM_BUSY (set MISTER_CLAIM_FORCE=1 to override)" >&2
      step "lock_acquire_busy"
      return 2
    fi
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  printf '%s\n' "$AGENT_ID" >"$LOCK_DIR/agent"
  printf '%s\n' "$(ts_iso)" >"$LOCK_DIR/timestamp"
  printf '%s\n' "$(date +%s)" >"$LOCK_DIR/timestamp_epoch"
  printf '%s\n' "$REASON" >"$LOCK_DIR/reason"
  printf '%s\n' "$HOST" >"$LOCK_DIR/host"
  printf '%s\n' "$ROOT" >"$LOCK_DIR/root"
  step "lock_acquired"
  return 0
}

release_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -z "$holder" || "$holder" == "$$" || "$FORCE" == "1" ]]; then
      rm -rf "$LOCK_DIR"
      step "lock_released"
      return 0
    fi
    echo "mister_soft_bounce: refuse release; holder pid=$holder != $$ (MISTER_CLAIM_FORCE=1 to override)" >&2
    step "lock_release_refused holder=$holder"
    return 3
  fi
  step "lock_released_already_free"
  return 0
}

# Read live CORENAME. Banner-filtered. Test inject: MISTER_CLAIM_FAKE_CORENAME
# (only honored with SKIP_BOUNCE=1 so a live run cannot be silently stubbed).
read_corename() {
  if [[ "$SKIP_BOUNCE" == "1" ]]; then
    printf '%s\n' "${MISTER_CLAIM_FAKE_CORENAME:-Plex}"
    return 0
  fi
  if [[ -n "${MISTER_CLAIM_FAKE_CORENAME:-}" ]]; then
    echo "mister_soft_bounce: REFUSED MISTER_CLAIM_FAKE_CORENAME on live bounce (SKIP_BOUNCE=0)" >&2
    return 4
  fi
  local raw
  raw="$(ssh_clean 'cat /tmp/CORENAME 2>/dev/null' | tr -d '\r' | tail -n 1)" || return $?
  printf '%s\n' "$raw"
}

# Required after every bounce: CORENAME must be Plex.
verify_corename_plex() {
  local phase="$1"
  local name
  step "corename_verify_begin phase=$phase"
  name="$(read_corename)" || return $?
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  audit "corename:$phase" "corename=${name:-empty}"
  if printf '%s' "$name" | grep -qiE '^plex$'; then
    echo "mister_soft_bounce: CORENAME_OK phase=$phase CORENAME=$name"
    step "corename_ok phase=$phase CORENAME=$name"
    if [[ -d "$LOCK_DIR" ]]; then
      printf '%s\n' "$name" >"$LOCK_DIR/corename" 2>/dev/null || true
    fi
    return 0
  fi
  cat >&2 <<EOF
mister_soft_bounce: CORENAME_NOT_PLEX phase=$phase CORENAME='${name:-empty}'
  Claim bounce did not leave the FPGA on Plex. A third-party loader (lab has
  MiSTer_Physical-CD / superdrive_* watchers) may have seized the core.
  Do NOT proceed as if Plex were live. Do NOT thrash load_core to "fix" it.
  Report this loudly and stop.
EOF
  audit "corename_fail:$phase" "corename=${name:-empty}"
  step "corename_not_plex phase=$phase CORENAME=${name:-empty}"
  return 5
}

# Opt-in bounded recovery after CORENAME_NOT_PLEX. Only via deploy_plex_core.sh.
recover_corename() {
  local phase="$1"
  if [[ "$RECOVER_MODE" != "reboot" ]]; then
    return 5
  fi
  if [[ "$SKIP_BOUNCE" == "1" ]]; then
    step "recover_skip_offline phase=$phase"
    audit_local "recover_skip:$phase" "mode=$RECOVER_MODE reason=skip_bounce"
    return 5
  fi
  step "recover_begin phase=$phase mode=reboot timeout_s=$RECOVER_TIMEOUT_S"
  audit "recover_begin:$phase" "mode=reboot timeout_s=$RECOVER_TIMEOUT_S"
  echo "mister_soft_bounce: RECOVER=reboot phase=$phase (bounded ${RECOVER_TIMEOUT_S}s, DEPLOY_SKIP_COPY=1)" >&2

  if ! command -v timeout >/dev/null 2>&1; then
    echo "mister_soft_bounce: GNU timeout required for recover" >&2
    return 127
  fi

  set +e
  timeout --foreground -k 5 "$RECOVER_TIMEOUT_S" \
    env \
      DEPLOY_LOAD=menu \
      DEPLOY_SKIP_COPY=1 \
      DEPLOY_RECOVER=reboot \
      DEPLOY_SKIP_GEOMETRY_GATE=1 \
      MISTER_HOST="$HOST" \
      MISTER_USER="$USER" \
      MISTER_PASS="$PASS" \
      DEPLOY_WAIT_S="$DEPLOY_WAIT_S" \
      bash "$ROOT/scripts/deploy_plex_core.sh"
  local rc=$?
  set -e

  if [[ "$rc" -eq 124 ]]; then
    echo "mister_soft_bounce: RECOVER TIMEOUT phase=$phase after ${RECOVER_TIMEOUT_S}s" >&2
    audit "recover_timeout:$phase" "limit_s=$RECOVER_TIMEOUT_S"
    step "recover_timeout phase=$phase"
    return 124
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: RECOVER FAILED phase=$phase rc=$rc" >&2
    audit "recover_fail:$phase:rc=$rc"
    step "recover_fail phase=$phase rc=$rc"
    return "$rc"
  fi
  audit "recover_ok:$phase"
  step "recover_ok phase=$phase"
  verify_corename_plex "recover:$phase" || return $?
  return 0
}

# ensure_daemon: deploy kills misterplexd and never restarts. After bounce we must.
ensure_daemon() {
  local phase="$1"
  step "ensure_daemon_begin phase=$phase id=$MISTERPLEX_ID"
  if [[ "$SKIP_BOUNCE" == "1" ]]; then
    step "ensure_daemon_skip phase=$phase"
    audit_local "ensure_daemon_skip:$phase" "id=$MISTERPLEX_ID"
    return 0
  fi

  local id_q
  id_q="$(printf '%q' "$MISTERPLEX_ID")"
  local remote_cmd
  remote_cmd="set +e
ID_WANT=${id_q}
if ps 2>/dev/null | grep -v grep | grep -q \"[m]isterplexd.*--id \${ID_WANT}\"; then
  echo \"DAEMON_ALREADY id=\${ID_WANT}\"
  exit 0
fi
if ps 2>/dev/null | grep -v grep | grep -q '[m]isterplexd'; then
  killall misterplexd 2>/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    ps 2>/dev/null | grep -v grep | grep -q '[m]isterplexd' || break
    sleep 0.25
  done
fi
cd /media/fat/misterplex || exit 1
if [ ! -x ./bin/misterplexd ]; then
  echo \"DAEMON_MISSING bin\" >&2
  exit 1
fi
nohup ./bin/misterplexd --name MiSTerPlex --id \${ID_WANT} --port 3005 \\
  --conf /media/fat/misterplex/misterplex.conf \\
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.5
if ps 2>/dev/null | grep -v grep | grep -q \"[m]isterplexd.*--id \${ID_WANT}\"; then
  echo \"DAEMON_STARTED id=\${ID_WANT}\"
  exit 0
fi
if ps 2>/dev/null | grep -v grep | grep -q '[m]isterplexd'; then
  echo \"DAEMON_STARTED id=\${ID_WANT} (pid-present)\"
  exit 0
fi
echo \"DAEMON_START_FAIL id=\${ID_WANT}\" >&2
exit 1"

  set +e
  local out
  out="$(ssh_raw "$remote_cmd" 2>/dev/null)"
  local rc=$?
  set -e
  if [[ "$rc" -eq 124 ]]; then
    die_timeout "ensure_daemon:$phase" "$SSH_TIMEOUT_S"
    return 124
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: WARN ensure_daemon phase=$phase rc=$rc out=${out:-}" >&2
    audit "ensure_daemon_warn:$phase" "rc=$rc id=$MISTERPLEX_ID"
    step "ensure_daemon_warn phase=$phase rc=$rc"
    return 0
  fi
  echo "mister_soft_bounce: ensure_daemon phase=$phase ok id=$MISTERPLEX_ID ${out:-}"
  audit "ensure_daemon_ok:$phase" "id=$MISTERPLEX_ID"
  step "ensure_daemon_ok phase=$phase id=$MISTERPLEX_ID"
  return 0
}

# Visible Menu → Plex via existing deploy path. Never copies an RBF.
soft_bounce() {
  local phase="$1"
  local limit_s="$BOUNCE_TIMEOUT_S"
  if [[ "$phase" == "release" || "$phase" == "release_cleanup" ]]; then
    limit_s="$CLEANUP_TIMEOUT_S"
  fi

  step "bounce_begin phase=$phase limit_s=$limit_s skip=$SKIP_BOUNCE"
  if [[ "$SKIP_BOUNCE" == "1" ]]; then
    echo "mister_soft_bounce: SKIP_BOUNCE=1 phase=$phase (no device touch)"
    audit_local "bounce_skip:$phase"
    # Unit-test hook: sleep so mid-bounce kill can prove trap releases lock.
    if [[ "$TEST_BOUNCE_SLEEP_S" =~ ^[0-9]+$ ]] && (( TEST_BOUNCE_SLEEP_S > 0 )); then
      step "test_bounce_sleep_begin s=$TEST_BOUNCE_SLEEP_S"
      sleep "$TEST_BOUNCE_SLEEP_S" &
      wait $! || true
      step "test_bounce_sleep_end"
    fi
    verify_corename_plex "$phase"
    local vrc=$?
    if [[ "$vrc" -ne 0 ]]; then
      if [[ "$vrc" -eq 5 && "$RECOVER_MODE" == "reboot" ]]; then
        recover_corename "$phase" || return $?
      else
        return "$vrc"
      fi
    fi
    ensure_daemon "$phase" || true
    step "bounce_end phase=$phase rc=0"
    return 0
  fi

  echo "mister_soft_bounce: visible soft bounce phase=$phase (DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 limit_s=$limit_s)"
  audit "bounce_begin:$phase"

  if ! command -v timeout >/dev/null 2>&1; then
    echo "mister_soft_bounce: GNU timeout required for bounded bounce" >&2
    return 127
  fi

  mkdir -p "$ROOT/build"
  local deploy_log
  deploy_log="$ROOT/build/mister-bounce-deploy.$$.$phase.log"

  # Stream deploy stdout so the user sees CORENAME polls live.
  set +e
  timeout --foreground -k 5 "$limit_s" \
    env \
      DEPLOY_LOAD=menu \
      DEPLOY_SKIP_COPY=1 \
      DEPLOY_RECOVER=none \
      DEPLOY_SKIP_GEOMETRY_GATE=1 \
      MISTER_HOST="$HOST" \
      MISTER_USER="$USER" \
      MISTER_PASS="$PASS" \
      DEPLOY_WAIT_S="$DEPLOY_WAIT_S" \
      bash "$ROOT/scripts/deploy_plex_core.sh" 2>&1 | tee "$deploy_log"
  local rc=${PIPESTATUS[0]}
  set -e

  if grep -qiE '^CORENAME=.*menu' "$deploy_log" 2>/dev/null; then
    step "menu_seen phase=$phase"
  fi
  if grep -qiE '^CORENAME=.*plex' "$deploy_log" 2>/dev/null; then
    step "plex_seen phase=$phase"
  fi

  if [[ "$rc" -eq 124 ]]; then
    echo "mister_soft_bounce: bounce phase=$phase TIMEOUT after ${limit_s}s" >&2
    audit "bounce_timeout:$phase" "limit_s=$limit_s"
    step "bounce_timeout phase=$phase"
    # Opt-in recover may still bring Plex back after a wedged/hung deploy.
    if [[ "$RECOVER_MODE" == "reboot" && "$phase" == "claim" ]]; then
      recover_corename "$phase" || return $?
      ensure_daemon "$phase" || true
      step "bounce_end phase=$phase rc=0 via=recover_after_timeout"
      return 0
    fi
    return 124
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: bounce phase=$phase FAILED rc=$rc" >&2
    audit "bounce_fail:$phase:rc=$rc"
    step "bounce_fail phase=$phase rc=$rc"
    # rc=3 Main wedged / rc=4 Menu ok but Plex never: opt-in soft reboot recover.
    if [[ "$RECOVER_MODE" == "reboot" && "$phase" == "claim" ]]; then
      recover_corename "$phase" || return $?
      ensure_daemon "$phase" || true
      step "bounce_end phase=$phase rc=0 via=recover_after_bounce_fail"
      return 0
    fi
    return "$rc"
  fi
  audit "bounce_ok:$phase"
  step "bounce_deploy_ok phase=$phase"

  verify_corename_plex "$phase"
  local vrc=$?
  if [[ "$vrc" -ne 0 ]]; then
    if [[ "$vrc" -eq 5 && "$RECOVER_MODE" == "reboot" ]]; then
      recover_corename "$phase" || return $?
    else
      return "$vrc"
    fi
  fi

  ensure_daemon "$phase" || true
  step "bounce_end phase=$phase rc=0"
  return 0
}

HOLDING=0
CLEANUP_RAN=0

# CRITICAL: release lock FIRST, then optional restore bounce.
# Old order (bounce then release) stranded the lock when bounce hung.
cleanup() {
  local ec=$?
  if [[ "$CLEANUP_RAN" == "1" ]]; then
    return 0
  fi
  CLEANUP_RAN=1
  trap - EXIT INT TERM HUP

  if [[ "$HOLDING" == "1" ]]; then
    HOLDING=0
    step "cleanup_begin exit_code=$ec"
    # Stop any in-flight bounce/ssh children so a hung deploy cannot outlive us.
    # TERM only — never kill -9 (lab rule).
    local child
    for child in $(jobs -pr 2>/dev/null); do
      kill -TERM "$child" 2>/dev/null || true
    done
    # 1) RELEASE LOCK FIRST — never leave stranded if restore hangs.
    FORCE=1 release_lock || true
    audit_local "release" "cleanup=1 prior_ec=$ec"
    # 2) Best-effort restore bounce (bounded). Failure must not re-hang.
    set +e
    if [[ "$SKIP_BOUNCE" == "1" ]]; then
      TEST_BOUNCE_SLEEP_S=0 soft_bounce "release_cleanup"
    else
      if command -v timeout >/dev/null 2>&1; then
        step "cleanup_restore_bounce_begin"
        timeout --foreground -k 5 "$CLEANUP_TIMEOUT_S" \
          env \
            DEPLOY_LOAD=menu \
            DEPLOY_SKIP_COPY=1 \
            DEPLOY_RECOVER=none \
            DEPLOY_SKIP_GEOMETRY_GATE=1 \
            MISTER_HOST="$HOST" \
            MISTER_USER="$USER" \
            MISTER_PASS="$PASS" \
            DEPLOY_WAIT_S="$DEPLOY_WAIT_S" \
            bash "$ROOT/scripts/deploy_plex_core.sh" \
          >/dev/null 2>&1 || true
        # Best-effort daemon restart after cleanup bounce (never -9)
        local id_q
        id_q="$(printf '%q' "$MISTERPLEX_ID")"
        timeout --foreground -k 5 "$SSH_TIMEOUT_S" \
          sshpass -p "$PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=12 \
            -o ServerAliveInterval=3 \
            -o ServerAliveCountMax=3 \
            -o NumberOfPasswordPrompts=1 \
            "$USER@$HOST" \
            "cd /media/fat/misterplex && (ps | grep -v grep | grep -q '[m]isterplexd' || nohup ./bin/misterplexd --name MiSTerPlex --id ${id_q} --port 3005 --conf /media/fat/misterplex/misterplex.conf >>/media/fat/misterplex/misterplexd.log 2>&1 &)" \
          >/dev/null 2>&1 || true
        step "cleanup_restore_bounce_end"
      fi
    fi
    set -e
    step "cleanup_end"
  fi
  exit "$ec"
}

do_claim() {
  acquire_lock || return $?
  HOLDING=1
  trap cleanup EXIT INT TERM HUP
  step "claim_begin"
  audit "claim"
  soft_bounce "claim" || return $?

  if [[ $# -gt 0 ]]; then
    step "command_start"
    echo "mister_soft_bounce: running under claim: $*"
    set +e
    "$@"
    local cmd_rc=$?
    set -e
    step "command_end rc=$cmd_rc"
    return "$cmd_rc"
  fi

  if [[ -n "$HOLD_S" ]]; then
    if ! [[ "$HOLD_S" =~ ^[0-9]+$ ]]; then
      echo "MISTER_CLAIM_HOLD_S must be non-negative integer" >&2
      return 2
    fi
    echo "mister_soft_bounce: holding claim for ${HOLD_S}s (agent=$AGENT_ID)"
    step "hold_begin s=$HOLD_S"
    sleep "$HOLD_S" &
    wait $! || true
    step "hold_end"
    return 0
  fi

  echo "mister_soft_bounce: holding claim until signal (agent=$AGENT_ID reason=$REASON)"
  step "hold_until_signal"
  while true; do
    sleep 3600 &
    wait $! || true
  done
}

do_release() {
  if [[ ! -d "$LOCK_DIR" ]]; then
    echo "CLAIM_FREE (nothing to release)"
    return 0
  fi
  print_lock_status
  if [[ "$FORCE" != "1" ]]; then
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null && [[ "$holder" != "$$" ]]; then
      echo "mister_soft_bounce: holder still alive pid=$holder; refuse (MISTER_CLAIM_FORCE=1)" >&2
      return 3
    fi
  fi
  # RELEASE LOCK FIRST, then best-effort return-to-Plex.
  step "release_external_begin"
  audit "release_external"
  FORCE=1 release_lock
  soft_bounce "release" || true
  echo "CLAIM_RELEASED"
  step "release_external_end"
}

case "$CMD" in
  claim)
    do_claim "$@"
    ;;
  release)
    do_release
    ;;
  status)
    print_lock_status
    ;;
  -h|--help|help|"")
    usage
    [[ -n "$CMD" ]] || exit 2
    exit 0
    ;;
  *)
    echo "Unknown command: $CMD (use claim|release|status)" >&2
    usage >&2
    exit 2
    ;;
esac
