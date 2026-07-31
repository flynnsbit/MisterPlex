#!/usr/bin/env bash
# rollback_v2.sh — HOST-SIDE restore of the known-good v0.2.0 daily driver.
#
# Why this exists: scripts/plexctl.sh reload-v2 is ON-DEVICE only. Running it on
# the lab host evaluates device paths with the host's [ -f ], which falsely
# reported "ERROR no core at /media/fat/_Utility/Plex_v2.rbf" three times while
# the file existed on the MiSTer (parent-measured 2026-07-31). A rollback tool
# that lies about the daily driver being destroyed is dangerous.
#
# This script always talks to the device over SSH (with retry/backoff for the
# lab's flaky "No route to host" drops). It never tests /media/fat paths on the
# local host.
#
# Known-good pin (parent 2026-07-31):
#   core   /media/fat/_Utility/Plex_v2.rbf          md5 dfebf2bfd08dd70b473b587dd7e81848
#   daemon /media/fat/misterplex_v2/bin/misterplexd md5 50f4eb925de10e29172999a565c87684
#   CORENAME=Plex (not distinctive — all Plex RBFs report this)
#   HTTP GET :3005/resources → 200
#
# Restore sequence (matches parent manual reference):
#   1) stop daemon (so binary replace is not ETXTBSY; no writers during reconfig)
#   2) menu.rbf bounce then load Plex_v2.rbf
#   3) start v2 bundle via on-device plexctl
#   4) verify LIVE /proc/<pid>/exe md5 + HTTP — never disk alone
#
# Exit codes (printed as "true rc=N" on the last line):
#   0  OK — live daemon matches pin and HTTP is healthy
#   2  MISSING — on-device check proved a required file is absent
#   3  MISMATCH — hash present but wrong
#   4  NO-DATA / CANNOT_CHECK — empty result after successful transport, or
#      ambiguous state (never report this as MISSING)
#   5  NETWORK — SSH failed after retries
#   9  HARD — stop/start/load sequence failed for a stated reason
#
# Usage (parent only — agents must not SSH to the device):
#   scripts/rollback_v2.sh              # full restore + verify
#   scripts/rollback_v2.sh verify       # check only
#   scripts/rollback_v2.sh restore      # restore + verify
#
# Test inject: ROLLBACK_SSH / ROLLBACK_HTTP override transports (no real device).

set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
SSH_TRIES="${ROLLBACK_SSH_TRIES:-6}"
SSH_BACKOFF_S="${ROLLBACK_SSH_BACKOFF_S:-1}"

V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_DAEMON=/media/fat/misterplex_v2/bin/misterplexd
V2_ROOT=/media/fat/misterplex_v2
MENU_CORE=/media/fat/menu.rbf
PLEXCTL_CANDIDATES="/media/fat/misterplex/bin/plexctl.sh /media/fat/misterplex_v2/bin/plexctl.sh /media/fat/Scripts/plexctl.sh"

CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
# Hybrid pin parent named as known-good for daily driver (50f4eb92).
DAEMON_MD5=50f4eb925de10e29172999a565c87684
# Also accept pristine v0.2.0 release asset if still on disk.
DAEMON_MD5_RELEASE=7cd10b4d438c714a9b8c4766dc982d59

PORT="${ROLLBACK_PORT:-3005}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { printf '%s %s\n' "$(ts)" "$*" >&2; }

# Capture rc WITHOUT a pipe (pipeline rc is the last command — trap that bit
# the parent three times). Caller:  out=$(run_ssh ...); rc=$?
run_ssh() {
  local remote="$1"
  local attempt=0 delay="$SSH_BACKOFF_S" out rc errf
  errf="${ROLLBACK_ERRFILE:-}"
  if [ -z "$errf" ]; then
    errf="$(pwd)/build/rollback-ssh.err"
    mkdir -p "$(dirname "$errf")"
  fi
  while [ "$attempt" -lt "$SSH_TRIES" ]; do
    attempt=$((attempt + 1))
    : >"$errf"
    set +e
    if [ -n "${ROLLBACK_SSH:-}" ]; then
      # shellcheck disable=SC2086
      out=$($ROLLBACK_SSH "$remote" 2>"$errf")
      rc=$?
    else
      out=$(sshpass -p "$PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=2 \
        -o ServerAliveCountMax=2 \
        "$USER@$HOST" "$remote" 2>"$errf")
      rc=$?
    fi
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    log "ssh-retry attempt=$attempt/${SSH_TRIES} rc=$rc err=$(tr '\n' ' ' <"$errf" | head -c 160)"
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 16 ] && delay=16
  done
  log "ssh-FAILED after ${SSH_TRIES} attempts (NETWORK) last_err=$(tr '\n' ' ' <"$errf" | head -c 200)"
  return 5
}

http_code() {
  local url="$1"
  local attempt=0 delay=1 code rc
  while [ "$attempt" -lt 4 ]; do
    attempt=$((attempt + 1))
    set +e
    if [ -n "${ROLLBACK_HTTP:-}" ]; then
      # shellcheck disable=SC2086
      code=$($ROLLBACK_HTTP "$url")
      rc=$?
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 4 "$url" 2>/dev/null)
      rc=$?
    fi
    set -e
    code=${code:-}
    if [ "$rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
      printf '%s' "$code"
      return 0
    fi
    log "http-retry attempt=$attempt code='${code}' rc=$rc"
    sleep "$delay"
    delay=$((delay * 2))
  done
  printf '%s' "${code:-}"
  return 5
}

# Classify a hash observation. Empty = NO-DATA (never MISSING/MISMATCH).
# Prints: OK|NO-DATA|MISSING|MISMATCH and returns 0|4|2|3.
classify_hash() {
  local label="$1" got="$2" want="$3"
  local alt="${4:-}"
  if [ -z "$got" ]; then
    echo "NO-DATA $label got='' (empty observation — not a mismatch; transport or remote cmd produced no hash)"
    return 4
  fi
  case "$got" in
    MISSING|missing|NOENT)
      echo "MISSING $label path absent on device"
      return 2
      ;;
  esac
  if [ "$got" = "$want" ] || { [ -n "$alt" ] && [ "$got" = "$alt" ]; }; then
    echo "OK $label $got"
    return 0
  fi
  echo "MISMATCH $label got='$got' want='$want'${alt:+ or '$alt'}"
  return 3
}

# Remote one-shot: disk md5 or MISSING; never silent empty on proven path check.
remote_file_md5() {
  local path="$1"
  # shellcheck disable=SC2016
  run_ssh "if [ ! -e $(printf '%q' "$path") ]; then echo MISSING; elif [ ! -f $(printf '%q' "$path") ]; then echo MISSING; else md5sum $(printf '%q' "$path") | awk '{print \$1}'; fi"
}

# Live daemon: exact argv0 = V2_DAEMON, md5 /proc/PID/exe, conf, port.
remote_live_daemon() {
  run_ssh "bin=$(printf '%q' "$V2_DAEMON"); $(cat <<'REMOTE'
set +e
n=0
pids=""
live=""
conf=""
port=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  [ -r "$d/cmdline" ] || continue
  cmd_nl=$(tr '\0' '\n' <"$d/cmdline" 2>/dev/null) || continue
  a0=$(printf '%s\n' "$cmd_nl" | head -n1)
  [ "$a0" = "$bin" ] || continue
  p=${d#/proc/}
  [ -d "/proc/$p" ] || continue
  pids="${pids}${pids:+ }$p"
  n=$((n + 1))
  conf=""; port=""; prev=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$prev" in
      --port) port="$tok"; prev=""; continue ;;
      --conf) conf="$tok"; prev=""; continue ;;
    esac
    case "$tok" in
      --port) prev=--port ;;
      --port=*) port="${tok#--port=}"; prev="" ;;
      --conf) prev=--conf ;;
      --conf=*) conf="${tok#--conf=}"; prev="" ;;
      *) prev="" ;;
    esac
  done <<TOKENS
$cmd_nl
TOKENS
done
echo "N_MATCH=$n"
echo "PIDS=$pids"
if [ "$n" -eq 1 ]; then
  pid=$pids
  if [ -e "/proc/$pid/exe" ]; then
    live=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
  fi
fi
echo "LIVE_MD5=${live}"
echo "LIVE_PORT=${port}"
echo "LIVE_CONF=${conf}"
REMOTE
)"
}

stop_remote_daemon() {
  log "stop remote daemon via plexctl (best effort)"
  local pc
  set +e
  pc=$(run_ssh "for p in $PLEXCTL_CANDIDATES; do [ -x \"\$p\" ] && echo \"\$p\" && break; done")
  local rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  if [ -z "$pc" ]; then
    log "NOTE no plexctl on device — killing misterplexd by argv0 match"
    run_ssh 'for d in /proc/[0-9]*; do
      [ -r "$d/cmdline" ] || continue
      a0=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null | head -n1)
      case "$a0" in
        */misterplexd) kill "${d#/proc/}" 2>/dev/null || true ;;
      esac
    done; sleep 1; echo stopped_by_argv0'
    return 0
  fi
  run_ssh "$pc stop; echo stop_rc=\$?"
}

load_v2_core_remote() {
  # Parent reference: menu bounce then Plex_v2. Never host-side [ -f ].
  log "load core: menu bounce then $V2_CORE"
  run_ssh "set -e
    if [ ! -e /dev/MiSTer_cmd ]; then echo 'NO-DATA missing /dev/MiSTer_cmd'; exit 4; fi
    if [ ! -f $(printf '%q' "$V2_CORE") ]; then echo 'MISSING $V2_CORE'; exit 2; fi
    if [ -f $(printf '%q' "$MENU_CORE") ]; then
      printf '%s\n' 'load_core $(printf '%s' "$MENU_CORE")' > /dev/MiSTer_cmd
      sleep 6
    else
      echo 'NOTE menu.rbf absent — loading V2 core directly'
    fi
    printf '%s\n' 'load_core $(printf '%s' "$V2_CORE")' > /dev/MiSTer_cmd
    sleep 8
    echo CORE_LOAD_ISSUED
    if [ -f /tmp/CORENAME ]; then echo CORENAME=\$(cat /tmp/CORENAME); fi
    if [ -f /tmp/RBFNAME ]; then echo RBFNAME=\$(cat /tmp/RBFNAME); fi
  "
}

start_v2_bundle() {
  log "start v2 bundle"
  local pc
  set +e
  pc=$(run_ssh "for p in $PLEXCTL_CANDIDATES; do [ -x \"\$p\" ] && echo \"\$p\" && break; done")
  local rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  if [ -z "$pc" ]; then
    log "ERROR no plexctl on device — CANNOT start bundle cleanly"
    return 9
  fi
  run_ssh "$pc v2; echo start_rc=\$?"
}

verify_only() {
  local rc=0 step_rc got_core got_disk live_blob live n pids port conf code

  log "== verify known-good v2 pins (honest empty=NO-DATA) =="

  set +e
  got_core=$(remote_file_md5 "$V2_CORE")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then
    echo "NETWORK core-md5"
    echo "true rc=5"
    return 5
  fi
  set +e
  classify_hash "core-disk" "$got_core" "$CORE_MD5"
  step_rc=$?
  set -e
  [ "$step_rc" -eq 0 ] || rc=$step_rc

  set +e
  got_disk=$(remote_file_md5 "$V2_DAEMON")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then
    echo "NETWORK daemon-disk-md5"
    echo "true rc=5"
    return 5
  fi
  set +e
  classify_hash "daemon-disk" "$got_disk" "$DAEMON_MD5" "$DAEMON_MD5_RELEASE"
  step_rc=$?
  set -e
  # disk is secondary; keep worst rc but do not let disk NO-DATA alone skip live
  if [ "$step_rc" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=$step_rc; fi
  if [ "$step_rc" -eq 2 ] || [ "$step_rc" -eq 3 ]; then rc=$step_rc; fi

  set +e
  live_blob=$(remote_live_daemon)
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then
    echo "NETWORK live-daemon-probe"
    echo "true rc=5"
    return 5
  fi
  printf '%s\n' "$live_blob"
  n=$(printf '%s\n' "$live_blob" | sed -n 's/^N_MATCH=//p' | head -1)
  live=$(printf '%s\n' "$live_blob" | sed -n 's/^LIVE_MD5=//p' | head -1)
  pids=$(printf '%s\n' "$live_blob" | sed -n 's/^PIDS=//p' | head -1)
  port=$(printf '%s\n' "$live_blob" | sed -n 's/^LIVE_PORT=//p' | head -1)
  conf=$(printf '%s\n' "$live_blob" | sed -n 's/^LIVE_CONF=//p' | head -1)
  n=${n:-}
  if [ -z "$n" ]; then
    echo "NO-DATA live-daemon (empty N_MATCH — transport/partial output, not n_daemon=0)"
    rc=4
  elif [ "$n" = "0" ]; then
    echo "FAIL live-daemon n_daemon=0 (no process with argv0=$V2_DAEMON)"
    rc=9
  elif [ "$n" != "1" ]; then
    echo "FAIL live-daemon multi-match n=$n pids='$pids'"
    rc=9
  else
    set +e
    classify_hash "daemon-live" "$live" "$DAEMON_MD5" "$DAEMON_MD5_RELEASE"
    step_rc=$?
    set -e
    if [ "$step_rc" -ne 0 ]; then rc=$step_rc; fi
    if [ -n "$conf" ]; then
      echo "OK daemon-conf $conf (from live --conf)"
    else
      echo "NOTE daemon-conf empty"
    fi
    # ETXTBSY: only when BOTH sides non-empty and differ
    if [ -n "$got_disk" ] && [ "$got_disk" != "MISSING" ] && [ -n "$live" ] && [ "$got_disk" != "$live" ]; then
      echo "FAIL daemon-disk/live mismatch disk='$got_disk' live='$live'"
      echo "     hint: cp over RUNNING binary fails ETXTBSY — stop, replace, restart, re-check /proc/PID/exe"
      rc=3
    fi
  fi

  port=${port:-$PORT}
  set +e
  code=$(http_code "http://${HOST}:${port}/resources")
  step_rc=$?
  set -e
  if [ -z "$code" ]; then
    echo "NO-DATA http /resources (empty code)"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$code" = "200" ] || [ "$code" = "204" ]; then
    echo "OK http /resources code=$code port=$port"
  elif [ "$step_rc" -eq 5 ]; then
    echo "NETWORK http /resources code='$code'"
    [ "$rc" -eq 0 ] && rc=5
  else
    echo "FAIL http /resources code=$code port=$port"
    rc=9
  fi

  echo "true rc=$rc"
  return "$rc"
}

restore_and_verify() {
  local rc
  set +e
  stop_remote_daemon
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi

  set +e
  load_v2_core_remote
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR core load sequence rc=$rc"
    echo "true rc=9"
    return 9
  fi

  set +e
  start_v2_bundle
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR start v2 bundle rc=$rc"
    echo "true rc=9"
    return 9
  fi

  # Give supervisor a moment; verify_only polls HTTP with its own retry.
  sleep "${ROLLBACK_POST_START_SLEEP:-4}"
  verify_only
}

cmd="${1:-restore}"
case "$cmd" in
  verify)  verify_only ;;
  restore) restore_and_verify ;;
  *)
    echo "usage: $0 {verify|restore}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
