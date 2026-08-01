#!/usr/bin/env bash
# Red-before-green for tools/soak_continuity_assert.py
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/soak_continuity_assert.py"
DIR="$ROOT/build/soak_continuity_$$"
mkdir -p "$DIR"
FAIL=0

run() {
  local name="$1" want="$2"
  shift 2
  python3 "$TOOL" "$@" >"$DIR/$name.out" 2>"$DIR/$name.err"
  local st=$?
  echo "$name true rc=$st want=$want"
  if [ "$st" -ne "$want" ]; then
    echo "FAIL $name"
    cat "$DIR/$name.out" "$DIR/$name.err" || true
    FAIL=$((FAIL + 1))
  fi
}

# OK: stable process_epoch + pid
cat >"$DIR/ok.log" <<'EOF'
media: frames=10 presents=10 drops=2 vfps=24 pfps=24 process_epoch=1001 pid=20943 session_epoch=1001.1 tag=measured
media: frames=100 presents=98 drops=2 vfps=24 pfps=23 process_epoch=1001 pid=20943 session_epoch=1001.1 tag=measured
media: frames=500 presents=498 drops=2 vfps=24 pfps=23 process_epoch=1001 pid=20943 session_epoch=1001.1 tag=measured
EOF
run ok 0 --log "$DIR/ok.log"

# FAIL: process_epoch changes (respawn)
cat >"$DIR/respawn.log" <<'EOF'
media: frames=10 presents=10 drops=2 process_epoch=1001 pid=20943 session_epoch=1001.1 tag=measured
media: frames=20 presents=18 drops=0 process_epoch=2002 pid=21000 session_epoch=2002.1 tag=measured
EOF
run respawn 2 --log "$DIR/respawn.log"

# FAIL: ledger process_exit in window
cat >"$DIR/led.log" <<'EOF'
ts=2026-01-01T00:00:00Z event=process_start pid=1 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
ts=2026-01-01T00:10:00Z event=process_exit pid=1 code=0 why=site=main.cpp:main_loop_g_stop sig=15
ts=2026-01-01T00:10:02Z event=process_start pid=2 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0
EOF
cat >"$DIR/led_media.log" <<'EOF'
media: frames=10 presents=10 drops=1 process_epoch=1001 pid=1 session_epoch=1001.1 tag=measured
EOF
run ledger_exit 2 --log "$DIR/led_media.log" --ledger "$DIR/led.log"

# NO-DATA: no process_epoch
cat >"$DIR/nodata.log" <<'EOF'
media: frames=10 presents=10 drops=2 vfps=24
EOF
run nodata 77 --log "$DIR/nodata.log"

# Stream change alone (same process_epoch) is OK without --require-single-session-epoch
cat >"$DIR/stream.log" <<'EOF'
media: frames=10 presents=10 drops=2 process_epoch=1001 pid=9 session_epoch=1001.1 tag=measured
media: frames=5 presents=5 drops=0 process_epoch=1001 pid=9 session_epoch=1001.2 tag=measured
EOF
run stream_ok 0 --log "$DIR/stream.log"

# Parent P4: counter soak must assert ONE session_epoch (stream change fails)
run stream_require_session 2 --log "$DIR/stream.log" --require-single-session-epoch

# Single session_epoch + stable process_epoch → OK under strict flag
cat >"$DIR/one_session.log" <<'EOF'
supply_bucket: fps=24/1 fps_src=caller_supplied session_epoch=1001.1 fpga_obs=none tag=measured
media: frames=10 presents=10 drops=2 process_epoch=1001 pid=9 session_epoch=1001.1 tag=measured
media: frames=500 presents=498 drops=2 process_epoch=1001 pid=9 session_epoch=1001.1 tag=measured
EOF
run one_session 0 --log "$DIR/one_session.log" --require-single-session-epoch

# No session_epoch + require → NO-DATA 77
cat >"$DIR/no_se.log" <<'EOF'
media: frames=10 presents=10 drops=2 process_epoch=1001 pid=9 tag=measured
EOF
run no_session_epoch 77 --log "$DIR/no_se.log" --require-single-session-epoch

if [ "$FAIL" -ne 0 ]; then
  echo "test_soak_continuity_assert: FAIL count=$FAIL"
  exit 1
fi
echo "test_soak_continuity_assert: OK"
exit 0
