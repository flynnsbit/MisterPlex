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
#
# JOIN SAFETY: this fragment is safe to append ONLY via gate_join_remote_parts
# (explicit \\n). Never do remote+="$(snippet)" after an echo "V2_MD5=$x" line —
# $(...) strips trailing NL and produces V2_MD5=<hex>set +e (parent blind-RED).
# Prefer inlining inside a single heredoc (promotion_gate_check remote_live_blob).
pair_remote_live_daemon_snippet() {
  cat <<'REMOTE'
# pair live identity fragment (errexit off on next line only)
set +e
n=0
pids=
live=
conf=
port=
exe=
root=
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
  conf=
  port=
  prev=
  if [ -r "$d/cmdline" ]; then
    cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || cmd=
    for tok in $cmd; do
      case "$prev" in
        --port) port="$tok"; prev=; continue ;;
        --conf) conf="$tok"; prev=; continue ;;
      esac
      case "$tok" in
        --port) prev=--port ;;
        --port=*) port="${tok#--port=}"; prev= ;;
        --conf) prev=--conf ;;
        --conf=*) conf="${tok#--conf=}"; prev= ;;
        *) prev= ;;
      esac
    done
  fi
done
printf 'N_DAEMON=%s\n' "$n"
printf 'PIDS=%s\n' "$pids"
printf 'LIVE_MD5=%s\n' "$live"
printf 'LIVE_EXE=%s\n' "$exe"
printf 'LIVE_PORT=%s\n' "$port"
printf 'LIVE_CONF=%s\n' "$conf"
printf 'LIVE_ROOT=%s\n' "$root"
printf 'LIVE_PROBE_DONE=%s\n' "1"
REMOTE
}
