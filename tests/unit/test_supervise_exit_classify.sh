#!/usr/bin/env bash
# Prove exit classification: SIGTERM default, SIGKILL, handled-SIGTERM→0.
# true rc captured DIRECTLY on wait (never through a pipe).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${ROOT}/build/supervise_exit_classify_$$"
mkdir -p "$DIR"
FAIL=0

gcc -O2 -o "$DIR/victim" -x c - <<'C'
#include <unistd.h>
int main(void){ for(;;) pause(); }
C
echo "victim_build true rc=$?"

gcc -O2 -o "$DIR/handled" -x c - <<'C'
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
static void h(int s){(void)s; _exit(0);}
int main(void){ signal(SIGTERM,h); for(;;) pause(); }
C
echo "handled_build true rc=$?"

gcc -O2 -Wall -o "$DIR/cap" "$ROOT/tools/death_capture_supervisor.c"
echo "cap_build true rc=$?"

# --- Shell wait classification (plexctl SUPERVISE_EXIT approx) ---
shell_case() {
  local name="$1" mode="$2" bin="$3"
  "$bin" &
  local child=$!
  sleep 0.15
  case "$mode" in
    TERM) kill -TERM "$child" ;;
    KILL) kill -KILL "$child" ;;
  esac
  wait "$child"
  local st=$?
  echo "$name shell_wait true rc=$st"
  if [ "$st" -ge 128 ]; then
    echo "$name class=WIFSIGNALED_approx signal=$((st-128))"
  else
    echo "$name class=WIFEXITED_approx exit_status=$st"
  fi
  case "$name" in
    shell_default_term)
      [ "$st" -ge 128 ] && [ $((st-128)) -eq 15 ] || { echo "FAIL $name"; FAIL=$((FAIL+1)); } ;;
    shell_kill9)
      [ "$st" -ge 128 ] && [ $((st-128)) -eq 9 ] || { echo "FAIL $name"; FAIL=$((FAIL+1)); } ;;
    shell_handled_term)
      [ "$st" -eq 0 ] || { echo "FAIL $name want exit 0"; FAIL=$((FAIL+1)); } ;;
  esac
}

shell_case shell_default_term TERM "$DIR/victim"
shell_case shell_kill9 KILL "$DIR/victim"
shell_case shell_handled_term TERM "$DIR/handled"

# --- death_capture_supervisor real waitpid WIF* ---
# Cap forks child; we send signal to child pid printed on SUPERVISE_SPAWN.
cap_case() {
  local name="$1" mode="$2" bin="$3" want="$4"
  local d="$DIR/cap_$name"
  mkdir -p "$d"
  # Run cap in background; parse SUPERVISE_SPAWN pid from its stderr file
  "$DIR/cap" --once --dir "$d" --log "$d/child.log" --label "$name" -- "$bin" \
    >"$d/cap.out" 2>"$d/cap.err" &
  local cap_pid=$!
  local child=""
  local i
  for i in $(seq 1 50); do
    child=$(sed -n 's/.*SUPERVISE_SPAWN.* pid=\([0-9][0-9]*\).*/\1/p' "$d/cap.err" 2>/dev/null | tail -1)
    [ -n "$child" ] && break
    sleep 0.05
  done
  if [ -z "$child" ]; then
    echo "FAIL $name no SUPERVISE_SPAWN pid"
    FAIL=$((FAIL+1))
    kill -KILL "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true
    return
  fi
  case "$mode" in
    TERM) kill -TERM "$child" ;;
    KILL) kill -KILL "$child" ;;
  esac
  wait "$cap_pid"
  local cap_rc=$?
  echo "$name cap_wait true rc=$cap_rc"
  local line
  line=$(grep SUPERVISE_EXIT "$d/death_capture.log" 2>/dev/null | tail -1 || true)
  echo "$name SUPERVISE_EXIT: $line"
  case "$want" in
    sig15)
      echo "$line" | grep -E 'WIFSIGNALED|wifsignaled=1|signal=15|SIGTERM' >/dev/null || {
        echo "FAIL $name want SIGTERM record got: $line"; FAIL=$((FAIL+1)); }
      [ "$cap_rc" -eq 143 ] || { echo "FAIL $name cap_rc want 143 got $cap_rc"; FAIL=$((FAIL+1)); }
      ;;
    sig9)
      echo "$line" | grep -E 'signal=9|SIGKILL' >/dev/null || {
        echo "FAIL $name want SIGKILL record got: $line"; FAIL=$((FAIL+1)); }
      [ "$cap_rc" -eq 137 ] || { echo "FAIL $name cap_rc want 137 got $cap_rc"; FAIL=$((FAIL+1)); }
      ;;
    exit0)
      echo "$line" | grep -E 'WIFEXITED|wifexited=1|exit_status=0' >/dev/null || {
        echo "FAIL $name want exit0 record got: $line"; FAIL=$((FAIL+1)); }
      [ "$cap_rc" -eq 0 ] || { echo "FAIL $name cap_rc want 0 got $cap_rc"; FAIL=$((FAIL+1)); }
      ;;
  esac
}

cap_case default_term TERM "$DIR/victim" sig15
cap_case kill9 KILL "$DIR/victim" sig9
cap_case handled_term TERM "$DIR/handled" exit0

if [ "$FAIL" -ne 0 ]; then
  echo "test_supervise_exit_classify: $FAIL FAIL(s)"
  exit 1
fi
echo "test_supervise_exit_classify: OK"
exit 0
