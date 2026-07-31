# pair_live_probe.inc.sh — shared host-side snippets for LIVE daemon identity.
# Source from promotion/rollback gates. Never SSHes by itself.
#
# HARD RULE (parent ERROR 14): never count daemons by cmdline substring.
# flock / supervisors embed "misterplexd" in argv and produced a false
# n_daemon / 0.0% CPU reading. Count ONLY when:
#   basename(readlink -f /proc/PID/exe) == misterplexd
# and then take md5sum of that exe path (same as /proc/PID/exe content).

# Emit a remote shell fragment that prints:
#   N_DAEMON= PIDS= LIVE_MD5= LIVE_EXE= LIVE_PORT= LIVE_CONF= LIVE_ROOT=
pair_remote_live_daemon_snippet() {
  cat <<'REMOTE'
set +e
n=0
pids=""
live=""
conf=""
port=""
exe=""
root=""
for d in /proc/[0-9]*; do
  [ -e "$d/exe" ] || continue
  p=${d#/proc/}
  # Identity from resolved exe ONLY — never cmdline (flock false positive).
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  case "$x" in
    *"(deleted)"*) continue ;;
  esac
  base=$(basename "$x" 2>/dev/null) || continue
  [ "$base" = "misterplexd" ] || continue
  # Confirm the open image is readable and is the real binary.
  m=$(md5sum "$d/exe" 2>/dev/null | awk '{print $1}')
  [ -n "$m" ] || continue
  n=$((n + 1))
  pids="${pids}${pids:+ }$p"
  exe=$x
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
echo "LIVE_PORT=${port}"
echo "LIVE_CONF=${conf}"
echo "LIVE_ROOT=${root}"
REMOTE
}
