# live_daemon_enum.sh — enumerate misterplexd without going blind mid-deploy.
#
# Failure mode (measured on hardware during hand-install):
#   After `mv bin/misterplexd bin/misterplexd.bak`, the live process's
#   /proc/<pid>/exe readlink becomes:
#     /media/fat/misterplex_v2/bin/misterplexd (deleted)
#   A matcher of the form  case $exe in */misterplexd)  does NOT match
#   because the string ends with "misterplexd (deleted)", not "misterplexd".
#   Result: false n_daemon=0 while /resources still returns 200.
#
# Rules:
#   1. Prefer /proc/*/cmdline argv0 (stable across rename-delete).
#   2. If matching exe path, use *misterplexd*  NOT  */misterplexd)
#   3. md5sum /proc/PID/exe still works on (deleted) inodes — use it.

# shellcheck shell=sh

# Echo PIDs whose argv0 contains "misterplexd" (or exact path if LIVE_DAEMON_ARGV0 set).
# LIVE_DAEMON_ARGV0=/media/fat/misterplex_v2/bin/misterplexd → exact argv0 match.
live_daemon_pids() {
  want=${LIVE_DAEMON_ARGV0:-}
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    [ -r "$d/cmdline" ] || continue
    p=${d#/proc/}
    cmd_nl=$(tr '\0' '\n' <"$d/cmdline" 2>/dev/null) || continue
    a0=$(printf '%s\n' "$cmd_nl" | head -n1)
    [ -n "$a0" ] || continue
    if [ -n "$want" ]; then
      [ "$a0" = "$want" ] || continue
    else
      case "$a0" in
        *misterplexd*) ;;
        *) continue ;;
      esac
    fi
    case "$a0" in
      *live_daemon_enum*) continue ;;
    esac
    echo "$p"
  done
}

live_daemon_count() {
  live_daemon_pids | wc -w | tr -d ' '
}

live_daemon_exe_path() {
  pid=$1
  [ -n "$pid" ] || return 1
  readlink -f "/proc/$pid/exe" 2>/dev/null || readlink "/proc/$pid/exe" 2>/dev/null
}

# True if exe path refers to misterplexd even when " (deleted)".
live_daemon_exe_is_ours() {
  path=$1
  case "$path" in
    *misterplexd*) return 0 ;;
    *) return 1 ;;
  esac
}

live_daemon_exe_md5() {
  pid=$1
  [ -e "/proc/$pid/exe" ] || return 1
  md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}'
}
