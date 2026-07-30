#!/usr/bin/env bash
# Self-contained proof that a supervise-style loop SIGCONTs a stopped Main after
# the "daemon" is kill -9'd. Runs on a host; does NOT touch the MiSTer device.
#
# Mirrors scripts/plexctl.sh resume_stopped_main(): scan /proc/*/cmdline for
# argv0 == /media/fat/MiSTer (we craft argv0 via execl), CONT if state T.
#
# Usage (from repo root or anywhere):
#   bash tests/hw/test_supervisor_resume_main.sh
# Exit 0 = PASS.

set -euo pipefail

# Prefer CWD scratch (agents must not write /tmp); parent may override WORKDIR.
WORKDIR="${WORKDIR:-./build/misterplex-resume-main-$$}"
mkdir -p "$WORKDIR"
cleanup() {
  if [[ -n "${FAKE_MAIN_PID:-}" ]] && kill -0 "$FAKE_MAIN_PID" 2>/dev/null; then
    kill -CONT "$FAKE_MAIN_PID" 2>/dev/null || true
    kill -KILL "$FAKE_MAIN_PID" 2>/dev/null || true
    wait "$FAKE_MAIN_PID" 2>/dev/null || true
  fi
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill -KILL "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [[ -n "${SUP_PID:-}" ]] && kill -0 "$SUP_PID" 2>/dev/null; then
    kill -KILL "$SUP_PID" 2>/dev/null || true
    wait "$SUP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

SLEEP_BIN=/bin/sleep
[[ -x $SLEEP_BIN ]] || SLEEP_BIN=/usr/bin/sleep

# Fake Main: argv0 exactly /media/fat/MiSTer (file need not exist).
"$SLEEP_BIN" 3600 &
# Cannot set argv0 of an already-running process — re-exec via a tiny wrapper.
kill $! 2>/dev/null || true
wait $! 2>/dev/null || true

# Use a C helper if available, else python os.execv with argv0 override.
python3 - <<'PY' &
import os, time
os.execv("/bin/sleep" if os.path.exists("/bin/sleep") else "/usr/bin/sleep",
         ["/media/fat/MiSTer", "3600"])
PY
FAKE_MAIN_PID=$!
sleep 0.2
kill -0 "$FAKE_MAIN_PID"

# Confirm cmdline argv0
CMD=$(tr '\0' ' ' < /proc/$FAKE_MAIN_PID/cmdline)
case "$CMD" in
  /media/fat/MiSTer*) ;;
  *) echo "FAIL fake Main cmdline='$CMD'"; exit 1 ;;
esac

# Dummy "daemon" the supervisor waits on
"$SLEEP_BIN" 3600 &
DAEMON_PID=$!

# Supervisor loop (same contract as plexctl write_supervisor resume_stopped_main)
cat > "$WORKDIR/supervise.sh" <<'EOF'
#!/bin/sh
set -u
DAEMON_PID="$1"
LOG="$2"
resume_stopped_main() {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    # first cmdline token only (argv0)
    a0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n1) || continue
    [ "$a0" = "/media/fat/MiSTer" ] || continue
    p=${d#/proc/}
    st=$(tr ')' '\n' < "$d/stat" 2>/dev/null | tail -n1 | awk '{print $1}')
    if [ "$st" = "T" ]; then
      kill -CONT "$p" 2>/dev/null || true
      echo "RESUME_MAIN pid=$p" >>"$LOG"
    fi
  done
}
# Wait for daemon; on any exit (incl. kill -9 → 137), resume Main then exit.
wait "$DAEMON_PID" || true
resume_stopped_main
EOF
chmod +x "$WORKDIR/supervise.sh"
: > "$WORKDIR/sup.log"
sh "$WORKDIR/supervise.sh" "$DAEMON_PID" "$WORKDIR/sup.log" &
SUP_PID=$!

# Put fake Main into T (session suspend analogue)
kill -STOP "$FAKE_MAIN_PID"
sleep 0.2
ST=$(tr ')' '\n' < /proc/$FAKE_MAIN_PID/stat | tail -n1 | awk '{print $1}')
[[ "$ST" == "T" ]] || { echo "FAIL expected T got $ST"; exit 1; }

# kill -9 the daemon — supervisor cannot rely on daemon atexit
kill -9 "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
wait "$SUP_PID" 2>/dev/null || true

# Assert Main was CONT'd
sleep 0.2
ST2=$(tr ')' '\n' < /proc/$FAKE_MAIN_PID/stat | tail -n1 | awk '{print $1}')
if [[ "$ST2" == "T" ]]; then
  echo "FAIL Main still T after supervise resume"
  cat "$WORKDIR/sup.log"
  exit 1
fi
if ! grep -q "RESUME_MAIN pid=$FAKE_MAIN_PID" "$WORKDIR/sup.log"; then
  echo "FAIL missing RESUME_MAIN log line"
  cat "$WORKDIR/sup.log"
  exit 1
fi

echo "test_supervisor_resume_main: OK (Main $FAKE_MAIN_PID was T → $ST2 after kill -9 daemon)"
exit 0
