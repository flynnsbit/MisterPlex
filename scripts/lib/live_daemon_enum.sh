#!/usr/bin/env bash
# live_daemon_enum.sh — identify RUNNING misterplexd without pattern blindness.
#
# Parent HW 2026-07-31 FOURTH instrument artifact:
#   After rename-in-place, /proc/PID/exe reads
#     /media/fat/misterplex_v2/bin/misterplexd (deleted)
#   A trailing-component glob `*/misterplexd)` does NOT match → n_daemon=0
#   while /resources still returns 200. Blind exactly during deploy.
#
# Binding rules (repo-wide):
#   1) Never identify by cmdline substring alone (flock trap → CPU 0.0).
#   2) Empty capture is NO-DATA, never a value to compare.
#   3) Absence of a process is NO-DATA for metrics like CPU — never 0.0.
#   4) Match /proc/PID/exe with *misterplexd* after stripping " (deleted)".
#   5) Prefer cross-check HTTP /resources when asserting liveness.
#
# Source: source scripts/lib/live_daemon_enum.sh
# Or emit remote snippet: live_daemon_remote_snippet

# Strip kernel " (deleted)" suffix from a readlink -f /proc/PID/exe path.
# Prints cleaned path on stdout.
live_daemon_strip_deleted() {
  local x="${1:-}"
  # Kernel formats: "path (deleted)" — sometimes with trailing space variants.
  x="${x% (deleted)}"
  x="${x% (deleted)}"
  printf '%s' "$x"
}

# True if resolved exe path (with or without deleted) is misterplexd binary.
# NOT a supervisor, NOT flock, NOT plexctl.
live_daemon_exe_is_misterplexd() {
  local x base
  x=$(live_daemon_strip_deleted "${1:-}")
  [ -n "$x" ] || return 1
  base=$(basename "$x" 2>/dev/null) || return 1
  # Exact basename after strip — not substring of longer names.
  [ "$base" = "misterplexd" ]
}

# Host-side: classify n_daemon observation.
# Args: n_daemon live_md5 http_code
# Prints classification; rc:
#   0 live OK (n==1 and md5 non-empty) OR (n==0 and http=200 → DEPLOY_IN_FLIGHT warning still 0 if ALLOW?)
#   1 FAIL multi
#   4 NO-DATA
#   3 FAIL zero without http cross-check pass
live_daemon_classify() {
  local n="${1:-}" live="${2:-}" http="${3:-}"
  if [ -z "$n" ]; then
    echo "NO-DATA n_daemon empty"
    return 4
  fi
  case "$n" in
    ''|*[!0-9]*) echo "NO-DATA n_daemon shape got='$n'"; return 4 ;;
  esac
  if [ "$n" -gt 1 ]; then
    echo "FAIL n_daemon=$n multi"
    return 1
  fi
  if [ "$n" -eq 1 ]; then
    if [ -z "$live" ]; then
      echo "NO-DATA live_md5 empty while n_daemon=1"
      return 4
    fi
    echo "OK n_daemon=1 live_md5=$live"
    return 0
  fi
  # n==0
  if [ -z "$http" ]; then
    echo "NO-DATA n_daemon=0 and no http cross-check"
    return 4
  fi
  if [ "$http" = "200" ]; then
    # Classic (deleted) blindness during deploy — process exists, matcher missed it.
    echo "FAIL n_daemon=0 but http=/resources 200 (matcher blind — check (deleted) exe path)"
    return 3
  fi
  echo "FAIL n_daemon=0 http=$http"
  return 3
}

# Remote BusyBox-safe snippet: enumerate via /proc/PID/exe (deleted-tolerant).
# Prints N_DAEMON= PIDS= LIVE_MD5= LIVE_EXE= LIVE_EXE_RAW= LIVE_PORT= LIVE_CONF= LIVE_ROOT= DELETED=
live_daemon_remote_snippet() {
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
  # Identity from resolved exe ONLY — never cmdline substring (flock trap).
  x_raw=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ -n "$x_raw" ] || continue
  # Parent 2026-07-31: do NOT skip "(deleted)" — that is the deploy-in-flight case.
  x=$x_raw
  case "$x" in
    *" (deleted)") x=${x%" (deleted)"}; deleted=1 ;;
  esac
  base=$(basename "$x" 2>/dev/null) || continue
  [ "$base" = "misterplexd" ] || continue
  # md5 of the still-mapped image (works even when path shows deleted).
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

# Static lint helper text for tests.
live_daemon_banned_patterns_doc() {
  cat <<'EOF'
BANNED (pattern-match blindness):
  case "$x" in */misterplexd)          # misses "path/misterplexd (deleted)"
  grep -c '[m]isterplexd$'             # $ cannot match cmdline with args
  case "$cmd" in *misterplexd*)        # flock false positive
REQUIRED:
  basename after strip " (deleted)" == misterplexd
  md5sum /proc/PID/exe
  empty → NO-DATA; cross-check /resources when n=0
EOF
}
