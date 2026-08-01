#!/usr/bin/env bash
# user_state_snapshot.sh — byte-exact backup/verify of USER-OWNED conf + MiSTer.ini.
#
# Never normalise, never rewrite. Parent runs on host (SSH) or injects paths.
#
#   OUT=./build/user-state-TS ./scripts/user_state_snapshot.sh snapshot
#   SNAP=./build/user-state-TS ./scripts/user_state_snapshot.sh verify
#   SNAP=./build/user-state-TS RESTORE_EXECUTE=0 ./scripts/user_state_snapshot.sh restore-plan
#
# Conf path MUST come from live daemon cmdline --conf when available
# (never hardcode misterplex vs misterplex_v2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
OUT="${OUT:-$ROOT/build/user-state-snapshot}"
SNAP="${SNAP:-$OUT}"
CMD="${1:-snapshot}"
INI_PATH="${MISTER_INI_PATH:-/media/fat/MiSTer.ini}"

ssh_m() {
  if [[ -n "${USER_STATE_SSHM:-}" ]]; then
    # shellcheck disable=SC2086
    $USER_STATE_SSHM "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
}

die() { echo "FAIL user_state: $*" >&2; echo "true rc=1"; exit 1; }

remote_probe() {
  # shellcheck disable=SC2016
  ssh_m 'set +e
n=0; conf=""; exe=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  is=0
  c=""; [ -r "$d/comm" ] && c=$(cat "$d/comm" 2>/dev/null || true)
  [ "$c" = "misterplexd" ] && is=1
  if [ "$is" -eq 0 ] && [ -r "$d/cmdline" ]; then
    a0=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null | head -n1)
    case "$a0" in */misterplexd|misterplexd) is=1 ;; esac
  fi
  [ "$is" -eq 1 ] || continue
  n=$((n+1))
  exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
  cmd=$(tr "\0" " " <"$d/cmdline" 2>/dev/null || true)
  set -- $cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then conf="${2:-}"; break; fi
    shift
  done
done
echo "N_DAEMON=$n"
echo "LIVE_EXE=$exe"
echo "LIVE_CONF=$conf"
if [ -n "$conf" ] && [ -f "$conf" ]; then
  md5sum "$conf"
  echo "CONF_BYTES=$(wc -c <"$conf" | tr -d " ")"
else
  echo "CONF_MISSING=1"
fi
ini="'"$INI_PATH"'"
if [ -f "$ini" ]; then
  md5sum "$ini"
  echo "INI_BYTES=$(wc -c <"$ini" | tr -d " ")"
else
  echo "INI_MISSING=1"
fi
'
}

cmd_snapshot() {
  mkdir -p "$OUT"
  local blob conf_path conf_md5 ini_md5
  set +e
  blob=$(remote_probe)
  rc=$?
  set -e
  printf '%s\n' "$blob" | tee "$OUT/probe.txt"
  echo "probe true rc=$rc"
  [[ "$rc" -eq 0 ]] || die "probe ssh failed"

  conf_path=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_CONF=//p' | tail -1)
  conf_md5=$(printf '%s\n' "$blob" | awk '/misterplex\.conf/{print $1; exit}')
  ini_md5=$(printf '%s\n' "$blob" | awk -v p="$INI_PATH" 'index($0,p){print $1; exit}')
  if [[ -z "$ini_md5" ]]; then
    ini_md5=$(printf '%s\n' "$blob" | awk '/MiSTer\.ini/{print $1; exit}')
  fi

  # Pull byte-exact copies when execute path has scp — parent uses:
  #   ssh cat conf > OUT/misterplex.conf
  if [[ "${USER_STATE_EXECUTE:-0}" == "1" && -n "$conf_path" ]]; then
    ssh_m "cat '$conf_path'" >"$OUT/misterplex.conf"
    ssh_m "cat '$INI_PATH'" >"$OUT/MiSTer.ini"
    conf_md5=$(md5sum "$OUT/misterplex.conf" | awk '{print $1}')
    ini_md5=$(md5sum "$OUT/MiSTer.ini" | awk '{print $1}')
  fi

  cat >"$OUT/pins.env" <<EOF
LIVE_CONF_PATH=${conf_path}
CONF_MD5=${conf_md5}
INI_PATH=${INI_PATH}
INI_MD5=${ini_md5}
SNAPSHOT_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  echo "WROTE $OUT/pins.env conf_md5=$conf_md5 ini_md5=$ini_md5"
  echo "true rc=0"
}

cmd_verify() {
  [[ -f "$SNAP/pins.env" ]] || die "missing $SNAP/pins.env"
  # shellcheck disable=SC1090
  source "$SNAP/pins.env"
  local blob conf_md5 ini_md5
  set +e
  blob=$(remote_probe)
  rc=$?
  set -e
  printf '%s\n' "$blob"
  conf_md5=$(printf '%s\n' "$blob" | awk '/misterplex\.conf/{print $1; exit}')
  ini_md5=$(printf '%s\n' "$blob" | awk '/MiSTer\.ini/{print $1; exit}')
  if [[ -f "$SNAP/misterplex.conf" ]]; then
    conf_md5=$(md5sum "$SNAP/misterplex.conf" | awk '{print $1}')
    # Prefer live from probe when execute
    local live_c
    live_c=$(printf '%s\n' "$blob" | awk '/misterplex\.conf/{print $1; exit}')
    [[ -n "$live_c" ]] && conf_md5=$live_c
  fi
  set +e
  user_state_assert_byte_exact conf "${conf_md5:-}" "${CONF_MD5:-}"
  c_rc=$?
  user_state_assert_byte_exact ini "${ini_md5:-}" "${INI_MD5:-}"
  i_rc=$?
  set -e
  echo "conf_verify true rc=$c_rc"
  echo "ini_verify true rc=$i_rc"
  if [[ "$c_rc" -ne 0 || "$i_rc" -ne 0 ]]; then
    echo "true rc=7"
    exit 7
  fi
  echo "USER_STATE_OK conf=$CONF_MD5 ini=$INI_MD5"
  echo "true rc=0"
}

cmd_restore_plan() {
  [[ -f "$SNAP/pins.env" ]] || die "missing $SNAP/pins.env"
  # shellcheck disable=SC1090
  source "$SNAP/pins.env"
  cat <<EOF
# USER-OWNED restore plan — byte-exact; parent executes. Never normalise.
# 1) conf:
#    scp $SNAP/misterplex.conf root@host:${LIVE_CONF_PATH:-/media/fat/misterplex_v2/misterplex.conf}
# 2) ini:
#    scp $SNAP/MiSTer.ini root@host:${INI_PATH}
# 3) verify md5:
#    CONF_MD5 expect ${CONF_MD5}
#    INI_MD5  expect ${INI_MD5}
# 4) ONE menu bounce only (full paths):
$(promotion_menu_bounce_cmd "${PRODUCT_CORE:-/media/fat/_Utility/Plex.rbf}")
# 5) Never kill -9 by name; kill <PID> only if needed after pidof/readlink identity.
EOF
  echo "true rc=0"
}

case "$CMD" in
  snapshot) cmd_snapshot ;;
  verify) cmd_verify ;;
  restore-plan) cmd_restore_plan ;;
  *)
    echo "usage: $0 snapshot|verify|restore-plan" >&2
    echo "true rc=2"
    exit 2
    ;;
esac
