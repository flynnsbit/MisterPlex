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


# Exact argv --id token equality (NOT substring).
# "misterplex-dev-old" must NOT match want=misterplex-dev.
# Returns 0 iff line contains a --id token whose value equals $2.
misterplex_argv_id_equals() {
  local line="$1"
  local want="$2"
  local -a toks=()
  # shellcheck disable=SC2206
  toks=( $line )
  local i=0
  local n=${#toks[@]}
  while (( i < n )); do
    local t="${toks[i]}"
    if [[ "$t" == "--id" ]]; then
      local got="${toks[i+1]:-}"
      [[ -n "$got" && "$got" == "$want" ]]
      return $?
    fi
    if [[ "$t" == --id=* ]]; then
      local got="${t#--id=}"
      [[ -n "$got" && "$got" == "$want" ]]
      return $?
    fi
    (( ++i ))
  done
  return 1
}

# True when LOCK_DIR exists and its pid file equals this shell's $$.
lock_is_ours() {
  [[ -d "$LOCK_DIR" ]] || return 1
  local holder=""
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [[ -n "$holder" && "$holder" == "$$" ]]
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
  # Same safety rule as release_lock: NEVER steal a live foreign holder's lock,
  # even with FORCE=1. FORCE / age only clear genuinely stale locks (empty pid
  # file or pid provably dead). Ambiguous cases refuse (conservative).
  [[ -d "$LOCK_DIR" ]] || return 0
  local age holder=""
  age="$(lock_age_s)"
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"

  if [[ -n "$holder" && "$holder" != "$$" ]] && kill -0 "$holder" 2>/dev/null; then
    echo "mister_soft_bounce: refuse break; live foreign holder pid=$holder (FORCE does not steal live locks)" >&2
    print_lock_status >&2
    step "lock_break_refused holder=$holder alive=1"
    audit_local "lock_break_refused" "holder=$holder alive=1 force=$FORCE"
    return 1
  fi

  local stale=0
  if [[ -z "$holder" ]]; then
    # Empty pid: only break with FORCE or age (mid-write TOCTOU → prefer refuse).
    if [[ "$FORCE" == "1" ]] || (( age >= STALE_S )); then
      stale=1
    fi
  elif [[ "$holder" == "$$" ]]; then
    stale=1
  elif ! kill -0 "$holder" 2>/dev/null; then
    # Dead pid — FORCE or aged-out.
    if [[ "$FORCE" == "1" ]] || (( age >= STALE_S )); then
      stale=1
    fi
  fi
  if [[ "$stale" != "1" ]]; then
    return 1
  fi

  # TOCTOU guard: re-read pid and refuse if a live foreign holder appeared.
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$holder" && "$holder" != "$$" ]] && kill -0 "$holder" 2>/dev/null; then
    echo "mister_soft_bounce: refuse break; holder became live pid=$holder (TOCTOU guard)" >&2
    step "lock_break_refused holder=$holder toctou=1"
    audit_local "lock_break_refused" "holder=$holder toctou=1"
    return 1
  fi

  echo "mister_soft_bounce: breaking stale lock (force=$FORCE age_s=$age stale_s=$STALE_S holder=${holder:-none})" >&2
  audit_local "lock_break" "holder=${holder:-none} age_s=$age force=$FORCE"
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
      echo "mister_soft_bounce: CLAIM_BUSY (FORCE clears stale/dead locks only; never steals a live holder)" >&2
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
  # NEVER delete a lock owned by a different *live* pid — not even with FORCE.
  # FORCE only clears genuinely stale locks (missing pid file, or dead pid).
  # acquire_lock / break_lock_if_allowed obey the same rule.
  if [[ ! -d "$LOCK_DIR" ]]; then
    step "lock_released_already_free"
    return 0
  fi
  local holder=""
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$holder" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
    step "lock_released"
    return 0
  fi
  local alive=0
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    alive=1
  fi
  if [[ "$alive" == "1" ]]; then
    echo "mister_soft_bounce: refuse release; live foreign holder pid=$holder != $$ (never force-delete live locks)" >&2
    step "lock_release_refused holder=$holder alive=1"
    return 3
  fi
  # Stale: empty pid or dead pid.
  if [[ -z "$holder" || "$FORCE" == "1" ]]; then
    rm -rf "$LOCK_DIR"
    step "lock_released stale=1 holder=${holder:-none}"
    return 0
  fi
  echo "mister_soft_bounce: refuse release; dead foreign holder pid=$holder (MISTER_CLAIM_FORCE=1 to clear stale)" >&2
  step "lock_release_refused holder=$holder alive=0"
  return 3
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
    # Offline unit path: optional inject for hard-fail mutation tests.
    if [[ -n "${MISTER_CLAIM_FAKE_DAEMON:-}" ]]; then
      case "${MISTER_CLAIM_FAKE_DAEMON}" in
        ok|OK)
          step "ensure_daemon_skip phase=$phase fake=ok id=$MISTERPLEX_ID"
          audit_local "ensure_daemon_skip:$phase" "id=$MISTERPLEX_ID fake=ok"
          return 0
          ;;
        missing|fail|FAIL)
          echo "mister_soft_bounce: DAEMON_FAIL phase=$phase id=$MISTERPLEX_ID reason=fake_missing" >&2
          step "ensure_daemon_fail phase=$phase reason=fake_missing"
          audit_local "ensure_daemon_fail:$phase" "id=$MISTERPLEX_ID reason=fake_missing"
          return 6
          ;;
        wrong_id|mismatch)
          echo "mister_soft_bounce: DAEMON_ID_MISMATCH phase=$phase want=$MISTERPLEX_ID got=misterplex-183 (fake)" >&2
          step "ensure_daemon_fail phase=$phase reason=fake_wrong_id"
          audit_local "ensure_daemon_fail:$phase" "id=$MISTERPLEX_ID reason=fake_wrong_id"
          return 7
          ;;
        *)
          echo "mister_soft_bounce: unknown MISTER_CLAIM_FAKE_DAEMON=${MISTER_CLAIM_FAKE_DAEMON}" >&2
          return 2
          ;;
      esac
    fi
    step "ensure_daemon_skip phase=$phase"
    audit_local "ensure_daemon_skip:$phase" "id=$MISTERPLEX_ID"
    return 0
  fi

  local id_q
  id_q="$(printf '%q' "$MISTERPLEX_ID")"
  # Remote: start if needed, then HARD-require argv --id match. Wrong id is worse
  # than missing (cast advertises but never answers). Never accept bare pid-present.
  local remote_cmd
  remote_cmd="set +e
ID_WANT=${id_q}
# Exact --id TOKEN match (not substring). misterplex-dev-old must NOT match misterplex-dev.
# BusyBox ash-safe: word-split argv line; compare next token after --id.
exact_id_match() {
  _line=\$1
  set -- \$_line
  while [ \$# -gt 0 ]; do
    if [ \"\$1\" = '--id' ]; then
      shift
      [ \"\$1\" = \"\$ID_WANT\" ] && return 0
      return 1
    fi
    case \"\$1\" in
      --id=*)
        _v=\${1#--id=}
        [ \"\$_v\" = \"\$ID_WANT\" ] && return 0
        return 1
        ;;
    esac
    shift
  done
  return 1
}
extract_id() {
  _line=\$1
  set -- \$_line
  while [ \$# -gt 0 ]; do
    if [ \"\$1\" = '--id' ]; then
      shift
      echo \"\$1\"
      return 0
    fi
    case \"\$1\" in
      --id=*) echo \"\${1#--id=}\"; return 0 ;;
    esac
    shift
  done
  return 1
}
ps_argv() {
  # BusyBox rejects --no-headers; prefer -o pid,ppid,args then fall back.
  ps -o pid,ppid,args 2>/dev/null || ps w 2>/dev/null || ps 2>/dev/null
}
have_want=0
have_any=0
wrong_id=''
while IFS= read -r line; do
  echo \"\$line\" | grep -q '[m]isterplexd' || continue
  have_any=1
  if exact_id_match \"\$line\"; then
    have_want=1
  else
    wid=\$(extract_id \"\$line\" 2>/dev/null)
    [ -n \"\$wid\" ] && wrong_id=\"\$wid\"
  fi
done <<EOF
\$(ps_argv)
EOF
if [ \"\$have_want\" = \"1\" ]; then
  echo \"DAEMON_ALREADY id=\${ID_WANT}\"
  exit 0
fi
if [ \"\$have_any\" = \"1\" ]; then
  echo \"DAEMON_WRONG_ID want=\${ID_WANT} got=\${wrong_id:-unknown} — stopping mismatched daemon\" >&2
  killall misterplexd 2>/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    ps_argv | grep -v grep | grep -q '[m]isterplexd' || break
    sleep 0.25
  done
fi
cd /media/fat/misterplex || { echo DAEMON_MISSING_DIR >&2; exit 1; }
if [ ! -x ./bin/misterplexd ]; then
  echo \"DAEMON_MISSING bin\" >&2
  exit 1
fi
nohup ./bin/misterplexd --name MiSTerPlex --id \${ID_WANT} --port 3005 \\
  --conf /media/fat/misterplex/misterplex.conf \\
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.5
# Re-verify exact argv --id token. Bare 'misterplexd running' is NOT success.
have_want=0
have_any=0
wrong_id=''
while IFS= read -r line; do
  echo \"\$line\" | grep -q '[m]isterplexd' || continue
  have_any=1
  if exact_id_match \"\$line\"; then
    have_want=1
  else
    wid=\$(extract_id \"\$line\" 2>/dev/null)
    [ -n \"\$wid\" ] && wrong_id=\"\$wid\"
  fi
done <<EOF
\$(ps_argv)
EOF
if [ \"\$have_want\" = \"1\" ]; then
  echo \"DAEMON_STARTED id=\${ID_WANT}\"
  exit 0
fi
if [ \"\$have_any\" = \"1\" ]; then
  echo \"DAEMON_ID_MISMATCH want=\${ID_WANT} got=\${wrong_id:-unknown}\" >&2
  exit 7
fi
echo \"DAEMON_START_FAIL id=\${ID_WANT}\" >&2
exit 6"

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
    cat >&2 <<EOF
mister_soft_bounce: DAEMON_FAIL phase=$phase rc=$rc id=$MISTERPLEX_ID
  Bounce cannot leave the device without a verified misterplexd --id $MISTERPLEX_ID.
  out=${out:-}
  Do NOT treat this claim as successful. Restore the daemon before releasing the user.
EOF
    audit "ensure_daemon_fail:$phase" "rc=$rc id=$MISTERPLEX_ID out=${out:-}"
    step "ensure_daemon_fail phase=$phase rc=$rc id=$MISTERPLEX_ID"
    return "$rc"
  fi
  # Defense in depth: host-side parse of remote stdout must name the wanted id.
  if ! printf '%s' "$out" | grep -qE "id=${MISTERPLEX_ID}([[:space:]]|$)"; then
    echo "mister_soft_bounce: DAEMON_FAIL phase=$phase id=$MISTERPLEX_ID reason=stdout_missing_id out=${out:-}" >&2
    audit "ensure_daemon_fail:$phase" "rc=7 id=$MISTERPLEX_ID reason=stdout_missing_id"
    step "ensure_daemon_fail phase=$phase reason=stdout_missing_id"
    return 7
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
    ensure_daemon "$phase" || return $?
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
      ensure_daemon "$phase" || return $?
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
      ensure_daemon "$phase" || return $?
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

  ensure_daemon "$phase" || return $?
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

  # Release when lock file is ours (pid==$$ written at acquire), NOT only when
  # HOLDING=1. A kill between acquire_lock and HOLDING=1 must still drop the lock.
  # NEVER FORCE-delete another live lane's lock (two-lanes-on-device failure mode).
  local owned=0
  if lock_is_ours; then
    owned=1
  fi
  if [[ "$owned" == "1" || "$HOLDING" == "1" ]]; then
    HOLDING=0
    step "cleanup_begin exit_code=$ec owned=$owned"
    # Stop any in-flight bounce/ssh children so a hung deploy cannot outlive us.
    # TERM only — never kill -9 (lab rule).
    local child
    for child in $(jobs -pr 2>/dev/null); do
      kill -TERM "$child" 2>/dev/null || true
    done
    # 1) RELEASE LOCK FIRST — never leave stranded if restore hangs.
    local did_release=0
    if lock_is_ours; then
      if release_lock; then
        did_release=1
      fi
    elif [[ -d "$LOCK_DIR" ]]; then
      local holder=""
      holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
      if [[ -z "$holder" ]] || ! kill -0 "$holder" 2>/dev/null; then
        echo "mister_soft_bounce: cleanup clearing stale lock holder=${holder:-none}" >&2
        if FORCE=1 release_lock; then
          did_release=1
        fi
      else
        echo "mister_soft_bounce: cleanup WILL NOT steal live lock pid=$holder (owned=$owned)" >&2
        step "cleanup_lock_foreign_live holder=$holder"
        audit_local "cleanup_lock_foreign_live" "holder=$holder"
      fi
    else
      step "lock_released_already_free"
      did_release=1
    fi
    audit_local "release" "cleanup=1 prior_ec=$ec owned=$owned did_release=$did_release"
    # 2) Restore bounce only if this claim owned/released the lock. Never bounce
    # while another live lane holds the device.
    if [[ "$owned" == "1" || "$did_release" == "1" ]]; then
      set +e
      step "cleanup_restore_bounce_begin"
      TEST_BOUNCE_SLEEP_S=0 soft_bounce "release_cleanup"
      local restore_rc=$?
      set -e
      if [[ "$restore_rc" -ne 0 ]]; then
        echo "mister_soft_bounce: CLEANUP_RESTORE_FAIL rc=$restore_rc (lock already released; device may need manual Plex/daemon restore)" >&2
        step "cleanup_restore_fail rc=$restore_rc"
        audit_local "cleanup_restore_fail" "rc=$restore_rc"
      else
        step "cleanup_restore_ok"
      fi
    else
      step "cleanup_skip_restore reason=foreign_live_lock"
    fi
    step "cleanup_end"
  fi
  exit "$ec"
}

do_claim() {
  # Install trap BEFORE acquire. Lock ownership is the pid file ($$), not HOLDING.
  # HOLDING is a secondary flag; cleanup releases whenever lock_is_ours.
  trap cleanup EXIT INT TERM HUP
  acquire_lock || return $?
  # Unit inject: sleep before HOLDING=1 to prove kill still releases via lock_is_ours.
  if [[ -n "${MISTER_CLAIM_TEST_HOLDING_DELAY_S:-}" && "${MISTER_CLAIM_TEST_HOLDING_DELAY_S}" != "0" ]]; then
    step "test_holding_delay_s=${MISTER_CLAIM_TEST_HOLDING_DELAY_S}"
    sleep "${MISTER_CLAIM_TEST_HOLDING_DELAY_S}" &
    wait $! || true
  fi
  HOLDING=1
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
  local holder=""
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$holder" && "$holder" != "$$" ]] && kill -0 "$holder" 2>/dev/null; then
    # Never steal a live foreign claim via release (FORCE does not override).
    echo "mister_soft_bounce: holder still alive pid=$holder; refuse release (never force-delete live locks)" >&2
    return 3
  fi
  # RELEASE LOCK FIRST, then best-effort return-to-Plex.
  step "release_external_begin"
  audit "release_external"
  if [[ "$holder" == "$$" ]]; then
    release_lock || return $?
  else
    # Stale (empty/dead pid): FORCE allowed only for non-live.
    FORCE=1 release_lock || return $?
  fi
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
