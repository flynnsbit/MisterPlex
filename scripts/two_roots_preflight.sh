#!/usr/bin/env bash
# two_roots_preflight.sh — HARD fail on silent v1 conf/ffmpeg fallback layout.
#
# Parent: live binary under misterplex_v2 but compiled defaults pointed at
# /media/fat/misterplex/. Missing v2 conf → silent DECODE=320x240 + other ffmpeg.
#
#   ./scripts/two_roots_preflight.sh              # print checks + device cmds
#   TWO_ROOTS_BLOB=... ./scripts/two_roots_preflight.sh check   # host inject
#   PREFLIGHT_EXECUTE=1 ./scripts/two_roots_preflight.sh check  # parent SSH
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
CMD="${1:-plan}"

ssh_m() {
  if [[ -n "${TWO_ROOTS_SSHM:-}" ]]; then
    # shellcheck disable=SC2086
    $TWO_ROOTS_SSHM "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
}

print_plan() {
  cat <<'EOF'
=== TWO-ROOTS PREFLIGHT ===
HARD fail if:
  - live exe install_root != live --conf directory root
  - $install_root/misterplex.conf missing while /media/fat/misterplex/misterplex.conf exists
  - live ffmpeg path (from log ffmpeg_path= or conf FFMPEG=) is under the other root

Parent read-only device commands:
  pid=$(pidof misterplexd | awk '{print $1}'); echo pid=$pid
  readlink -f /proc/$pid/exe
  tr '\0' ' ' < /proc/$pid/cmdline; echo
  # conf path from cmdline --conf only
  md5sum /media/fat/misterplex/misterplex.conf /media/fat/misterplex_v2/misterplex.conf
  md5sum /media/fat/misterplex/bin/ffmpeg /media/fat/misterplex_v2/bin/ffmpeg
  cmp -s /media/fat/misterplex/bin/ffmpeg /media/fat/misterplex_v2/bin/ffmpeg; echo "ffmpeg_cmp true rc=$?"
  ls -l /media/fat/misterplex_v2/misterplex.conf

Daemon fix (install-root bind, refuse foreign): branch w-480-delivery @ 1fa15ec8
  host/libmisterplex/install_paths.hpp + main.cpp resolve — missing install conf rc=12.

Host check inject:
  TWO_ROOTS_BLOB=$'INSTALL_ROOT=/media/fat/misterplex_v2\nLIVE_CONF=...\nINSTALL_CONF_EXISTS=0\nFOREIGN_CONF_EXISTS=1' \
    ./scripts/two_roots_preflight.sh check; echo "true rc=$?"
EOF
  echo "true rc=0"
}

cmd_check() {
  local blob install_root live_conf ice fce
  if [[ -n "${TWO_ROOTS_BLOB:-}" ]]; then
    blob="$TWO_ROOTS_BLOB"
  elif [[ "${PREFLIGHT_EXECUTE:-0}" == "1" ]]; then
    blob=$(ssh_m 'set +e
exe=""; conf=""; n=0
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  is=0; c=""
  [ -r "$d/comm" ] && c=$(cat "$d/comm" 2>/dev/null || true)
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
# install_root = parent of bin/
root=""
case "$exe" in
  */bin/misterplexd) root=${exe%/bin/misterplexd} ;;
  *) root=$(dirname "$exe" 2>/dev/null) ;;
esac
echo "N_DAEMON=$n"
echo "LIVE_EXE=$exe"
echo "INSTALL_ROOT=$root"
echo "LIVE_CONF=$conf"
if [ -n "$root" ] && [ -f "$root/misterplex.conf" ]; then echo INSTALL_CONF_EXISTS=1; else echo INSTALL_CONF_EXISTS=0; fi
if [ -f /media/fat/misterplex/misterplex.conf ]; then echo FOREIGN_CONF_EXISTS=1; else echo FOREIGN_CONF_EXISTS=0; fi
if [ -f /media/fat/misterplex/bin/ffmpeg ]; then echo FOREIGN_FFMPEG_EXISTS=1; else echo FOREIGN_FFMPEG_EXISTS=0; fi
if [ -n "$root" ] && [ -x "$root/bin/ffmpeg" ]; then echo INSTALL_FFMPEG_EXISTS=1; else echo INSTALL_FFMPEG_EXISTS=0; fi
')
  else
    echo "FAIL need TWO_ROOTS_BLOB= or PREFLIGHT_EXECUTE=1" >&2
    echo "true rc=2"
    exit 2
  fi
  printf '%s\n' "$blob"
  install_root=$(printf '%s\n' "$blob" | sed -n 's/^INSTALL_ROOT=//p' | tail -1)
  live_conf=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_CONF=//p' | tail -1)
  ice=$(printf '%s\n' "$blob" | sed -n 's/^INSTALL_CONF_EXISTS=//p' | tail -1)
  fce=$(printf '%s\n' "$blob" | sed -n 's/^FOREIGN_CONF_EXISTS=//p' | tail -1)
  set +e
  deploy_assert_two_roots_safe "$install_root" "$live_conf" "${ice:-0}" "${fce:-0}"
  rc=$?
  set -e
  # Extra: install ffmpeg missing while foreign exists
  local iff fff
  iff=$(printf '%s\n' "$blob" | sed -n 's/^INSTALL_FFMPEG_EXISTS=//p' | tail -1)
  fff=$(printf '%s\n' "$blob" | sed -n 's/^FOREIGN_FFMPEG_EXISTS=//p' | tail -1)
  if [[ "$rc" -eq 0 && "${iff:-1}" != "1" && "${fff:-0}" == "1" ]]; then
    echo "FAIL two-roots: install ffmpeg missing while foreign ffmpeg exists" >&2
    rc=13
  fi
  echo "true rc=$rc"
  exit "$rc"
}

case "$CMD" in
  plan|"") print_plan ;;
  check) cmd_check ;;
  *)
    echo "usage: $0 plan|check" >&2
    echo "true rc=2"
    exit 2
    ;;
esac
