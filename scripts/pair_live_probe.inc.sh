# pair_live_probe.inc.sh — shared host-side snippets for LIVE daemon identity.
# Source from promotion/rollback gates. Never SSHes by itself.
#
# HARD RULE (parent ERROR 14 + 2026-07-31 (deleted) class):
#   never count daemons by cmdline substring (flock → false n_daemon / 0.0% CPU).
#   never use trailing glob `*/misterplexd)` — misses `misterplexd (deleted)`.
# Count ONLY when basename(strip_deleted(readlink -f /proc/PID/exe)) == misterplexd
# and then take md5sum of /proc/PID/exe (works while deleted).
# Empty capture = NO-DATA. n_daemon=0 + HTTP 200 = matcher blind FAIL.

_PAIR_LIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/live_daemon_enum.sh
if [ -f "$_PAIR_LIVE_ROOT/scripts/lib/live_daemon_enum.sh" ]; then
  # shellcheck disable=SC1091
  source "$_PAIR_LIVE_ROOT/scripts/lib/live_daemon_enum.sh"
fi

# Emit a remote shell fragment that prints:
#   N_DAEMON= PIDS= LIVE_MD5= LIVE_EXE= LIVE_EXE_RAW= LIVE_PORT= LIVE_CONF= LIVE_ROOT= DELETED=
pair_remote_live_daemon_snippet() {
  if declare -F live_daemon_remote_snippet >/dev/null 2>&1; then
    live_daemon_remote_snippet
    return
  fi
  cat <<'REMOTE'
set +e
n=0
pids=""
live=""
conf=""
port=""
exe=""
exe_raw=""
root=""
deleted=0
for d in /proc/[0-9]*; do
  [ -e "$d/exe" ] || continue
  p=${d#/proc/}
  x_raw=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ -n "$x_raw" ] || continue
  x=$x_raw
  case "$x" in
    *" (deleted)") x=${x%" (deleted)"}; deleted=1 ;;
  esac
  base=$(basename "$x" 2>/dev/null) || continue
  [ "$base" = "misterplexd" ] || continue
  m=$(md5sum "$d/exe" 2>/dev/null | awk '{print $1}')
  [ -n "$m" ] || continue
  n=$((n + 1))
  pids="${pids}${pids:+ }$p"
  exe=$x
  exe_raw=$x_raw
  live=$m
  root=$(dirname "$(dirname "$x")")
  conf=""; port=""; prev=""
  if [ -r "$d/cmdline" ]; then
    cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || cmd=""
    for tok in $cmd; do
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
    done
  fi
done
echo "N_DAEMON=$n"
echo "PIDS=$pids"
echo "LIVE_MD5=${live}"
echo "LIVE_EXE=${exe}"
echo "LIVE_EXE_RAW=${exe_raw}"
echo "LIVE_PORT=${port}"
echo "LIVE_CONF=${conf}"
echo "LIVE_ROOT=${root}"
echo "DELETED=${deleted}"
REMOTE
}
