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
# lock and soft-bounces back to Plex so the device is usable again.
#
# Env:
#   MISTER_HOST              default 192.168.1.183
#   MISTER_PASS              default 1
#   MISTER_USER              default root
#   MISTER_CLAIM_LOCK        lock dir (default: <repo>/build/mister-claim.lock)
#   MISTER_CLAIM_LOG         local audit log (default: <repo>/build/mister-claim-audit.log)
#   MISTER_CLAIM_REMOTE_LOG  device audit log (default: /media/fat/misterplex/claim-audit.log)
#   MISTER_CLAIM_STALE_S     stale lock age seconds (default: 7200)
#   MISTER_CLAIM_FORCE=1     break a held/stale lock (documented override)
#   MISTER_CLAIM_AGENT       agent id (default: user@host-pid)
#   MISTER_CLAIM_REASON      reason string
#   MISTER_CLAIM_SKIP_BOUNCE=1
#                            local-only: exercise lock/audit without touching device
#   MISTER_CLAIM_HOLD_S      hold seconds when no command given (default: infinity)
#   DEPLOY_WAIT_S            settle window forwarded to deploy bounce (default 5)
#
# Bounce mechanism (do not invent another):
#   DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh
# which is the Menu → wait → Plex path in deploy_plex_core.sh. Never flashes a
# different RBF (SKIP_COPY). Never thrash load_core; never kill -9 from here.
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
STALE_S="${MISTER_CLAIM_STALE_S:-7200}"
FORCE="${MISTER_CLAIM_FORCE:-0}"
SKIP_BOUNCE="${MISTER_CLAIM_SKIP_BOUNCE:-0}"
HOLD_S="${MISTER_CLAIM_HOLD_S:-}"
AGENT_ID="${MISTER_CLAIM_AGENT:-}"
REASON="${MISTER_CLAIM_REASON:-}"
DEPLOY_WAIT_S="${DEPLOY_WAIT_S:-5}"

CMD="${1:-}"
shift || true

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
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

# Filter OpenSSH post-quantum warning banners (bug 19dde00) before any parse.
ssh_raw() {
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "mister_soft_bounce: sshpass required for device ops" >&2
    return 127
  fi
  # shellcheck disable=SC2029
  sshpass -p "$PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=12 \
    -o ServerAliveInterval=3 \
    "$USER@$HOST" "$@"
}

ssh_clean() {
  # stdout only; strip known banner fragments if they ever land on stdout
  ssh_raw "$@" 2>/dev/null | grep -Ev 'post-quantum|OpenSSH_[0-9]|WARNING:|^\*\*\*' || true
}

audit_local() {
  local event="$1"
  mkdir -p "$(dirname "$LOCAL_LOG")"
  printf '%s event=%s agent=%s pid=%s host=%s reason=%s lock=%s\n' \
    "$(ts_iso)" "$event" "$AGENT_ID" "$$" "$HOST" "$REASON" "$LOCK_DIR" >>"$LOCAL_LOG"
}

audit_remote() {
  local event="$1"
  [[ "$SKIP_BOUNCE" == "1" ]] && return 0
  local line
  line="$(printf '%s event=%s agent=%s pid=%s host=%s reason=%s' \
    "$(ts_iso)" "$event" "$AGENT_ID" "$$" "$HOST" "$REASON")"
  # Append-only; never rewrite conf. Create parent dir if missing.
  ssh_raw "mkdir -p /media/fat/misterplex && printf '%s\n' $(printf '%q' "$line") >>$(printf '%q' "$REMOTE_LOG")" \
    >/dev/null 2>&1 || {
      echo "mister_soft_bounce: WARN remote audit append failed (local audit still written)" >&2
      return 0
    }
}

audit() {
  local event="$1"
  audit_local "$event"
  audit_remote "$event"
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
    # best-effort parse; unknown → 0 age handled by caller
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
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    :
  else
    if break_lock_if_allowed; then
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        print_lock_status >&2
        echo "mister_soft_bounce: CLAIM_BUSY after break attempt" >&2
        return 2
      fi
    else
      print_lock_status >&2
      echo "mister_soft_bounce: CLAIM_BUSY (set MISTER_CLAIM_FORCE=1 to override)" >&2
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
  return 0
}

release_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -z "$holder" || "$holder" == "$$" || "$FORCE" == "1" ]]; then
      rm -rf "$LOCK_DIR"
      return 0
    fi
    echo "mister_soft_bounce: refuse release; holder pid=$holder != $$ (MISTER_CLAIM_FORCE=1 to override)" >&2
    return 3
  fi
  return 0
}

# Visible Menu → Plex via existing deploy path. Never copies an RBF.
soft_bounce() {
  local phase="$1"
  if [[ "$SKIP_BOUNCE" == "1" ]]; then
    echo "mister_soft_bounce: SKIP_BOUNCE=1 phase=$phase (no device touch)"
    audit_local "bounce_skip:$phase"
    return 0
  fi
  echo "mister_soft_bounce: visible soft bounce phase=$phase (DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1)"
  audit "bounce_begin:$phase"
  # Reuse deploy_plex_core.sh menu bounce ONLY. Do not invent load_core thrash.
  # DEPLOY_SKIP_COPY=1 → no RBF scp/flash. DEPLOY_RECOVER=none → no reboot surprise.
  # Geometry gate soft-skips when daemon log unavailable after bounce; never treat as PASS.
  set +e
  DEPLOY_LOAD=menu \
  DEPLOY_SKIP_COPY=1 \
  DEPLOY_RECOVER=none \
  DEPLOY_SKIP_GEOMETRY_GATE=1 \
  MISTER_HOST="$HOST" \
  MISTER_USER="$USER" \
  MISTER_PASS="$PASS" \
  DEPLOY_WAIT_S="$DEPLOY_WAIT_S" \
    bash "$ROOT/scripts/deploy_plex_core.sh"
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mister_soft_bounce: bounce phase=$phase FAILED rc=$rc" >&2
    audit "bounce_fail:$phase:rc=$rc"
    return "$rc"
  fi
  audit "bounce_ok:$phase"
  return 0
}

HOLDING=0
cleanup() {
  local ec=$?
  trap - EXIT INT TERM
  if [[ "$HOLDING" == "1" ]]; then
    # Return device to usable Plex core, then drop lock.
    soft_bounce "release" || true
    audit "release"
    FORCE=1 release_lock || true
    HOLDING=0
  fi
  exit "$ec"
}

do_claim() {
  acquire_lock || return $?
  HOLDING=1
  trap cleanup EXIT INT TERM
  audit "claim"
  soft_bounce "claim" || return $?

  if [[ $# -gt 0 ]]; then
    echo "mister_soft_bounce: running under claim: $*"
    "$@"
    return $?
  fi

  if [[ -n "$HOLD_S" ]]; then
    if ! [[ "$HOLD_S" =~ ^[0-9]+$ ]]; then
      echo "MISTER_CLAIM_HOLD_S must be non-negative integer" >&2
      return 2
    fi
    echo "mister_soft_bounce: holding claim for ${HOLD_S}s (agent=$AGENT_ID)"
    # Background + wait so TERM/INT traps run immediately (bash defers traps
    # while a foreground sleep builtin/command is in progress).
    sleep "$HOLD_S" &
    wait $! || true
    return 0
  fi

  echo "mister_soft_bounce: holding claim until signal (agent=$AGENT_ID reason=$REASON)"
  # Interruptible idle; cleanup trap releases on INT/TERM/EXIT.
  while true; do
    sleep 3600 &
    wait $! || true
  done
}

do_release() {
  # External release: only if force or we can identify lock; bounce back to plex.
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
  # Best-effort return-to-Plex then drop lock.
  SKIP_SAVE="$SKIP_BOUNCE"
  soft_bounce "release" || true
  audit "release_external"
  FORCE=1 release_lock
  echo "CLAIM_RELEASED"
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
