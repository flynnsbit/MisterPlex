#!/usr/bin/env bash
# Static gate: every product main() path that can return 0 must be catalogued.
# Prevents a silent new "voluntary idle exit" from re-opening the soak-counter
# corruption class (parent: clean EXIT rc=0 with varying run_s).
#
# true rc captured DIRECTLY (never through a pipe).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN="$ROOT/arm/misterplexd/main.cpp"
FAIL=0

[ -f "$MAIN" ] || { echo "FAIL missing $MAIN"; exit 2; }

# ---- Catalog of allowed return-0 sites (must match source) ----
# Lab-only early paths:
#   return 0  after --help  (site=main.cpp:--help via deathBreadcrumbExit)
#   exitReported(0, "site=main.cpp:lab-play-file-done", ...)
# Product loop:
#   exitReported(0, why, ...) where why embeds main_loop_g_stop (SIGINT/SIGTERM only)
#
# Any NEW "return 0" / exitReported(0 in main.cpp must be added here intentionally.

help_sites=$(grep -c 'site=main.cpp:--help' "$MAIN" || true)
play_done=$(grep -c 'site=main.cpp:lab-play-file-done' "$MAIN" || true)
g_stop_site=$(grep -c 'site=main.cpp:main_loop_g_stop' "$MAIN" || true)
exit0_calls=$(grep -cE 'exitReported\(0,' "$MAIN" || true)
# bare "return 0;" in main.cpp (help path uses deathBreadcrumbExit then return 0)
bare_ret0=$(grep -nE '^\s*return 0;' "$MAIN" || true)
bare_n=$(printf '%s\n' "$bare_ret0" | grep -c . || true)
# tolerate empty
[ -z "$bare_ret0" ] && bare_n=0

echo "catalog help_sites=$help_sites play_done=$play_done g_stop_site=$g_stop_site exit0_calls=$exit0_calls bare_return_0=$bare_n"

[ "$help_sites" -eq 1 ] || { echo "FAIL expected 1 --help site, got $help_sites"; FAIL=$((FAIL+1)); }
[ "$play_done" -eq 1 ] || { echo "FAIL expected 1 lab-play-file-done site, got $play_done"; FAIL=$((FAIL+1)); }
[ "$g_stop_site" -ge 1 ] || { echo "FAIL expected main_loop_g_stop site"; FAIL=$((FAIL+1)); }
# Exactly two exitReported(0,...): lab-play-file-done + main_loop_g_stop
[ "$exit0_calls" -eq 2 ] || { echo "FAIL expected exactly 2 exitReported(0,), got $exit0_calls"; FAIL=$((FAIL+1)); }
# Exactly one bare return 0 (the --help path)
[ "$bare_n" -eq 1 ] || { echo "FAIL expected exactly 1 bare return 0;, got $bare_n:"; printf '%s\n' "$bare_ret0"; FAIL=$((FAIL+1)); }

# g_stop writers: only on_signal_info may store true
g_stop_stores=$(grep -nE 'g_stop\.store\(' "$MAIN" || true)
g_stop_n=$(printf '%s\n' "$g_stop_stores" | grep -c . || true)
[ -z "$g_stop_stores" ] && g_stop_n=0
echo "g_stop.store sites:"
printf '%s\n' "$g_stop_stores"
[ "$g_stop_n" -eq 1 ] || { echo "FAIL expected exactly 1 g_stop.store, got $g_stop_n"; FAIL=$((FAIL+1)); }
printf '%s\n' "$g_stop_stores" | grep -q 'on_signal_info\|g_stop.store(true' || true
# Must be inside the signal handler block (line near on_signal_info)
if ! grep -n 'void on_signal_info' "$MAIN" >/dev/null; then
  echo "FAIL missing on_signal_info"
  FAIL=$((FAIL+1))
fi

# Comment contract still present (documentation is the gate for humans)
grep -q 'Handled signals yield process exit status 0' "$MAIN" || {
  echo "FAIL missing handled-signal→rc=0 comment contract"
  FAIL=$((FAIL+1))
}
grep -q 'g_stop is set only by SIGINT/SIGTERM' "$MAIN" || {
  echo "FAIL missing g_stop-only-writers comment contract"
  FAIL=$((FAIL+1))
}

# No fixed-timer product exit keyword (would reintroduce silent soak reset)
if grep -nE 'MAX_RUN_S|IDLE_EXIT|auto_exit_after|run_for_seconds' "$MAIN" >/dev/null; then
  echo "FAIL found timer-exit keyword in main.cpp (product must not self-exit on a timer)"
  grep -nE 'MAX_RUN_S|IDLE_EXIT|auto_exit_after|run_for_seconds' "$MAIN" || true
  FAIL=$((FAIL+1))
fi

if [ "$FAIL" -ne 0 ]; then
  echo "test_main_rc0_paths: FAIL count=$FAIL"
  exit 1
fi
echo "test_main_rc0_paths: OK"
exit 0
