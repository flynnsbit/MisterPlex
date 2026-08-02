#!/usr/bin/env bash
# rollback_daemon_atomic.sh — ONE-COMMAND restore of a known-good misterplexd.
#
# Parent incident 2026-08-01: truncated scp left a corpse ELF; ETXTBSY blocked
# cp onto the live path while supervise held the (deleted) inode. Recovery:
#   stage → md5 → mv -f → kill by PID → verify /proc/exe.
#
# Usage (parent host; agents never SSH):
#   scripts/rollback_daemon_atomic.sh
#     # default pin: artifacts/daemon-pins/misterplexd.9ce2c2d1
#   scripts/rollback_daemon_atomic.sh 9ce2c2d1
#   scripts/rollback_daemon_atomic.sh /path/to/misterplexd
#   ROLLBACK_DAEMON=device:/media/fat/misterplex_v2/bin/misterplexd.9ce2c2d1.bak \
#     scripts/rollback_daemon_atomic.sh
#
# Does NOT touch USER-OWNED conf. Does NOT load_core. Daemon only.
# For full pair (core+daemon+hook): scripts/restore_misterplexd_prev.sh + PAIR_ID.
#
# Exit: true rc=0 on live /proc/exe md5 match + n_daemon=1 + /resources 200.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"
# shellcheck source=rbf_ship_policy.sh
source "$ROOT/scripts/rbf_ship_policy.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PORT="${MISTERPLEX_PORT:-3005}"
ARG="${1:-}"

ssh_m() {
  if [[ -n "${DEPLOY_SSHM:-}" ]]; then
    # shellcheck disable=SC2086
    $DEPLOY_SSHM "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
}
scp_to() {
  local src="$1" dst="$2"
  if [[ -n "${DEPLOY_SCPM:-}" ]]; then
    # shellcheck disable=SC2086
    $DEPLOY_SCPM "$src" "$dst"
    return
  fi
  case "$dst" in
    */misterplexd|*/misterplexd/)
      echo "FAIL scp to live path $dst forbidden" >&2
      return 9
      ;;
  esac
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$src" "$USER@$HOST:$dst"
}

resolve_src() {
  local a="${1:-}" pin
  if [[ -n "${ROLLBACK_DAEMON:-}" ]]; then
    printf '%s' "$ROLLBACK_DAEMON"
    return 0
  fi
  if [[ -z "$a" ]]; then
    a="${DAEMON_PIN_DDR_PRIMARY_PREFIX8:-9ce2c2d1}"
  fi
  if [[ -f "$a" ]]; then
    printf '%s' "$a"
    return 0
  fi
  pin="$ROOT/artifacts/daemon-pins/misterplexd.${a:0:8}"
  if [[ -f "$pin" ]]; then
    printf '%s' "$pin"
    return 0
  fi
  # prefix only — try device bak via special marker
  printf 'device:/media/fat/misterplex_v2/bin/misterplexd.%s.bak' "${a:0:8}"
}

SRC_SPEC=$(resolve_src "$ARG")
echo "rollback_daemon: src_spec=$SRC_SPEC"

# Resolve live root
LIVE_BLOB=$(ssh_m 'set +e
n=0; root=""; pids=""
for d in /proc/[0-9]*; do
  [ -e "$d/exe" ] || continue
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$x" in *"(deleted)"*) x=${x% (deleted)};; esac
  b=$(basename "$x" 2>/dev/null) || continue
  [ "$b" = "misterplexd" ] || continue
  n=$((n+1)); pids="$pids ${d#/proc/}"
  root=$(dirname "$(dirname "$x")")
done
# default v2 if none
[ -n "$root" ] || root=/media/fat/misterplex_v2
echo "N=$n"
echo "PIDS=$pids"
echo "ROOT=$root"
echo "BIN=$root/bin/misterplexd"
')
LIVE_ROOT=$(printf '%s\n' "$LIVE_BLOB" | sed -n 's/^ROOT=//p' | head -1)
REMOTE_BIN=$(printf '%s\n' "$LIVE_BLOB" | sed -n 's/^BIN=//p' | head -1)
CAPTURED=$(printf '%s\n' "$LIVE_BLOB" | sed -n 's/^PIDS=//p' | head -1)
echo "rollback_daemon: live_root=$LIVE_ROOT bin=$REMOTE_BIN pids=$CAPTURED"

# Materialize host bytes
HOST_BIN=""
WANT=""
if [[ "$SRC_SPEC" == device:* ]]; then
  devpath=${SRC_SPEC#device:}
  HOST_BIN="$ROOT/build/rollback-daemon.$$.bin"
  mkdir -p "$ROOT/build"
  set +e
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$USER@$HOST:$devpath" "$HOST_BIN"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || ! -f "$HOST_BIN" ]]; then
    echo "FAIL cannot fetch device bak $devpath"
    echo "true rc=2"
    exit 2
  fi
else
  HOST_BIN=$SRC_SPEC
  [[ -f "$HOST_BIN" ]] || {
    echo "FAIL missing pin $HOST_BIN — run scripts/pin_daemon_artifact.sh or fetch_daemon_pins.sh"
    echo "true rc=10"
    exit 10
  }
fi
WANT=$(md5sum "$HOST_BIN" | awk '{print $1}')
echo "rollback_daemon: want_md5=$WANT"

STAGED="${REMOTE_BIN}.stage.rollback.${WANT:0:8}"
set +e
scp_to "$HOST_BIN" "$STAGED"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL scp stage true rc=$rc"; echo "true rc=5"; exit 5; }

set +e
sm=$(ssh_m "md5sum $(printf '%q' "$STAGED")" | awk '{print $1}')
set -e
set +e
deploy_assert_stage_md5 "$WANT" "$sm"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  ssh_m "rm -f $(printf '%q' "$STAGED")" >/dev/null 2>&1 || true
  echo "true rc=$rc"
  exit "$rc"
fi

# Atomic mv + kill PIDs + verify live
set +e
ssh_m "set -e
  staged=$(printf '%q' "$STAGED")
  dst=$(printf '%q' "$REMOTE_BIN")
  want=$(printf '%q' "$WANT")
  sm=\$(md5sum \"\$staged\" | awk '{print \$1}')
  [ \"\$sm\" = \"\$want\" ] || { echo FAIL_STAGE; rm -f \"\$staged\"; exit 7; }
  # bak current if present
  if [ -f \"\$dst\" ]; then
    om=\$(md5sum \"\$dst\" | awk '{print \$1}')
    cp -p \"\$dst\" \"\${dst}.\${om:0:8}.bak\" 2>/dev/null || true
  fi
  mv -f \"\$staged\" \"\$dst\"
  chmod 755 \"\$dst\"
  sync
  dm=\$(md5sum \"\$dst\" | awk '{print \$1}')
  [ \"\$dm\" = \"\$want\" ] || { echo FAIL_DISK \$dm; exit 7; }
  echo DISK_OK=\$dm
  for p in $CAPTURED; do
    [ -n \"\$p\" ] || continue
    kill \"\$p\" 2>/dev/null || true
  done
  # also kill any remaining misterplexd by exe basename (PID loop, not killall)
  for d in /proc/[0-9]*; do
    [ -e \"\$d/exe\" ] || continue
    x=\$(readlink -f \"\$d/exe\" 2>/dev/null) || continue
    b=\$(basename \"\$x\" 2>/dev/null) || continue
    [ \"\$b\" = misterplexd ] || continue
    kill \${d#/proc/} 2>/dev/null || true
  done
  echo KILL_DONE
"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL atomic install true rc=$rc"; echo "true rc=$rc"; exit "$rc"; }

# Await live match
ok=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  set +e
  blob=$(ssh_m 'set +e
n=0; live=""; conf=""; root=""
for d in /proc/[0-9]*; do
  [ -e "$d/exe" ] || continue
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$x" in *"(deleted)"*) continue;; esac
  b=$(basename "$x" 2>/dev/null) || continue
  [ "$b" = misterplexd ] || continue
  m=$(md5sum "$d/exe" 2>/dev/null | awk "{print \$1}")
  n=$((n+1)); live=$m; root=$(dirname "$(dirname "$x")")
  conf=""
  if [ -r "$d/cmdline" ]; then
    cmd=$(tr "\0" " " <"$d/cmdline")
    case "$cmd" in *--conf\ *) conf=${cmd#*--conf }; conf=${conf%% *};; esac
  fi
done
echo "N=$n"
echo "LIVE=$live"
echo "CONF=$conf"
echo "ROOT=$root"
')
  set -e
  n=$(printf '%s\n' "$blob" | sed -n 's/^N=//p' | head -1)
  live=$(printf '%s\n' "$blob" | sed -n 's/^LIVE=//p' | head -1)
  conf=$(printf '%s\n' "$blob" | sed -n 's/^CONF=//p' | head -1)
  root=$(printf '%s\n' "$blob" | sed -n 's/^ROOT=//p' | head -1)
  if [[ "$n" == "1" && "$live" == "$WANT" ]]; then
    ok=1
    break
  fi
  sleep 1
done

set +e
http=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${HOST}:${PORT}/resources" 2>/dev/null || echo 000)
set -e
echo "rollback_daemon: n=$n live=$live want=$WANT http=$http"

set +e
deploy_assert_postconditions "${n:-0}" "${live:-}" "$WANT" "${conf:-$LIVE_ROOT/misterplex.conf}" \
  "${root:-$LIVE_ROOT}" "$http" "SKIP" "SKIP"
prc=$?
set -e
if [[ "$ok" -ne 1 || "$prc" -ne 0 ]]; then
  echo "FAIL rollback_daemon postconditions rc=$prc"
  echo "true rc=${prc:-3}"
  exit "${prc:-3}"
fi

echo "ROLLBACK_DAEMON_OK md5=$WANT root=$LIVE_ROOT"
echo "true rc=0"
exit 0
