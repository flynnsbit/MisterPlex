#!/usr/bin/env bash
# Host gate: product misterplexd_supervise.sh must attribute handled-SIGTERM→rc=0.
# Red if bare EXIT without death/si_pid/log_tail fields (parent blind 80× rc=0).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUP="$ROOT/scripts/misterplexd_supervise.sh"
FAIL=0

[ -f "$SUP" ] || { echo "FAIL missing $SUP"; exit 2; }

need() {
  local pat="$1" msg="$2"
  if ! grep -qE "$pat" "$SUP"; then
    echo "FAIL missing $msg ($pat)"
    FAIL=$((FAIL + 1))
  else
    echo "OK $msg"
  fi
}

need 'EXIT pid=.*rc=.*run_s=' 'legacy EXIT prefix for parent greps'
need 'WIFEXITED_approx' 'exit-class token'
need 'WIFSIGNALED_approx' 'signal-class token'
need 'si_pid=' 'si_pid field'
need 'si_code_name=' 'si_code_name field'
need 'sender_cmd=' 'sender_cmd field'
need 'sender_chain=' 'sender_chain field'
need 'death=\[' 'death snap'
need 'log_tail=\[' 'log_tail snap'
need 'EXIT_REASON\|main_loop exit pending' 'choke-point log grep'
need 'misterplexd\.death' 'death path'
need 'HEALTHY_SECS' 'backoff health window'
need 'resume_stopped_main' 'Main CONT sweep'
need '/media/fat/MiSTer' 'exact Main argv0'

# Must NOT treat rc=0 as voluntary without death attribution comment
if ! grep -q 'handled SIGTERM' "$SUP" && ! grep -q 'Handled SIGTERM' "$SUP" && ! grep -qi 'handled.SIGTERM\|rc=0' "$SUP"; then
  echo "FAIL missing comment that rc=0 can be handled SIGTERM"
  FAIL=$((FAIL + 1))
else
  echo "OK rc=0/handled-SIGTERM contract comment"
fi

# Static main catalog still green
sh "$ROOT/tests/unit/test_main_rc0_paths.sh"
main_rc=$?
echo "test_main_rc0_paths true rc=$main_rc"
[ "$main_rc" -eq 0 ] || FAIL=$((FAIL + 1))

# Handled-SIGTERM → shell wait 0 (existing classify gate if present)
if [ -x "$ROOT/tests/unit/test_supervise_exit_classify.sh" ] || [ -f "$ROOT/tests/unit/test_supervise_exit_classify.sh" ]; then
  sh "$ROOT/tests/unit/test_supervise_exit_classify.sh"
  cls_rc=$?
  echo "test_supervise_exit_classify true rc=$cls_rc"
  [ "$cls_rc" -eq 0 ] || FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -ne 0 ]; then
  echo "test_supervise_rc0_attribution: FAIL count=$FAIL"
  exit 1
fi
echo "test_supervise_rc0_attribution: OK"
exit 0
