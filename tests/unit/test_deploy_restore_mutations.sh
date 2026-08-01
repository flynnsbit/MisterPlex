#!/usr/bin/env bash
# Mutation tests for deploy + restore daily-driver gates.
#
# Model: tests/unit/test_soak_continuity_assert.sh — inject the defect, assert
# non-zero. GREP IS NOT EVIDENCE. A mutation that does not go red is a FINDING.
#
# Host-only. Never touches 192.168.1.183. Never mutates device conf.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/build/deploy_restore_mutations_$$"
mkdir -p "$DIR"
FAIL=0
FINDINGS=0

run_capture() {
  local name="$1"
  shift
  set +e
  "$@" >"$DIR/${name}.out" 2>&1
  local st=$?
  set -e
  echo "${name} true rc=${st}"
  echo "$st" >"$DIR/${name}.rc"
  return 0
}

expect_nonzero() {
  local name="$1" why="$2"
  local st
  st=$(cat "$DIR/${name}.rc")
  if [[ "$st" -eq 0 ]]; then
    echo "FINDING ${name}: mutation stayed GREEN (rc=0) — gate cannot catch: ${why}"
    FINDINGS=$((FINDINGS + 1))
    FAIL=$((FAIL + 1))
    tail -20 "$DIR/${name}.out" | sed 's/^/  /'
  else
    echo "PASS ${name}: red rc=${st} (${why})"
  fi
}

expect_rc() {
  local name="$1" want="$2" why="$3"
  local st
  st=$(cat "$DIR/${name}.rc")
  if [[ "$st" -ne "$want" ]]; then
    echo "FAIL ${name}: want rc=${want} got ${st} (${why})"
    FAIL=$((FAIL + 1))
    tail -20 "$DIR/${name}.out" | sed 's/^/  /'
  else
    echo "PASS ${name}: rc=${st} (${why})"
  fi
}

echo "=== coverage empty-inspection mutation ==="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/gate_coverage.inc.sh"
gate_coverage_begin "empty-probe" >"$DIR/cov_empty.out"
set +e
gate_coverage_finish 0 >>"$DIR/cov_empty.out"
echo $? >"$DIR/cov_empty.rc"
set -e
echo "cov_empty true rc=$(cat "$DIR/cov_empty.rc")"
expect_rc cov_empty 77 "rc=0 with zero notes must be UNSCORED"

gate_coverage_begin "with-notes" >"$DIR/cov_ok.out"
gate_coverage_note "n1" "looked" >>"$DIR/cov_ok.out"
set +e
gate_coverage_finish 0 >>"$DIR/cov_ok.out"
echo $? >"$DIR/cov_ok.rc"
set -e
echo "cov_ok true rc=$(cat "$DIR/cov_ok.rc")"
expect_rc cov_ok 0 "coverage with notes may PASS"

echo "=== artifact_pair missing stamp ==="
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/artifact_pair.inc.sh"
unset ARTIFACT_PAIR_RBF_MD5 ARTIFACT_PAIR_DAEMON_MD5
set +e
artifact_pair_stamp "soak" >"$DIR/pair_miss.out" 2>&1
echo $? >"$DIR/pair_miss.rc"
set -e
echo "pair_miss true rc=$(cat "$DIR/pair_miss.rc")"
expect_rc pair_miss 77 "measurement without pair is UNSCORED"

export ARTIFACT_PAIR_RBF_MD5=c5382bee73cecdee8220b811e529c297
export ARTIFACT_PAIR_DAEMON_MD5=7c991e47aaaaaaaaaaaaaaaaaaaaaaaa
set +e
artifact_pair_stamp "soak" >"$DIR/pair_ok.out" 2>&1
echo $? >"$DIR/pair_ok.rc"
set -e
echo "pair_ok true rc=$(cat "$DIR/pair_ok.rc")"
expect_rc pair_ok 0 "pair present"
grep -q 'ARTIFACT_PAIR' "$DIR/pair_ok.out" && echo "PASS pair_ok prints stamp" || {
  echo "FAIL pair_ok missing ARTIFACT_PAIR line"; FAIL=$((FAIL + 1))
}

echo "=== RESTORE: hard-refuse path (half-restore banned) R1-R6 style ==="
# Current restore_misterplexd_prev refuses without PAIR_ID (rc=10). Mutations
# that would have fooled the old md5sum||true script must still be non-zero.
RESTORE="$ROOT/scripts/restore_misterplexd_prev.sh"
chmod +x "$RESTORE"

# R1: delete PREV — script must not claim success
run_capture restore_r1 env -u PAIR_ID PREV_BIN=/no/such/prev "$RESTORE"
expect_rc restore_r1 10 "R1 missing PREV still REFUSE (no half restore)"

# R2: empty PREV file
: >"$DIR/empty.prev"
run_capture restore_r2 env -u PAIR_ID PREV_BIN="$DIR/empty.prev" "$RESTORE"
expect_rc restore_r2 10 "R2 empty PREV REFUSE"

# R3: PREV exists with bytes — old script would cp and exit 0 discarding md5
printf 'daemon-bytes-AAA\n' >"$DIR/prev.bin"
run_capture restore_r3 env -u PAIR_ID PREV_BIN="$DIR/prev.bin" "$RESTORE"
expect_rc restore_r3 10 "R3 PREV present still REFUSE without PAIR_ID (no silent cp)"

# R4/R5/R6 without PAIR_ID: still refuse
run_capture restore_r4 env -u PAIR_ID RESTORE_ALLOW_HALF=1 PREV_BIN="$DIR/prev.bin" "$RESTORE"
expect_rc restore_r4 10 "R4 RESTORE_ALLOW_HALF ignored permanently"

run_capture restore_r5 env -u PAIR_ID PREV_BIN="$DIR/prev.bin" RESTORE_EXPECT_GEOM=480 "$RESTORE"
expect_rc restore_r5 10 "R5 geometry not silently skipped via half-restore"

run_capture restore_r6 env -u PAIR_ID PREV_BIN="$DIR/prev.bin" "$RESTORE"
expect_rc restore_r6 10 "R6 no process-age path without pair identity"

echo "=== RESTORE POSTCONDITIONS checker (host temp root) — R3/R5 first ==="
PC="$ROOT/scripts/restore_postconditions.sh"
chmod +x "$PC"

setup_root() {
  local r="$1"
  rm -rf "$r"
  mkdir -p "$r/bin" "$r/state"
  printf 'good-daemon-payload-v1\n' >"$r/prev.bin"
  cp -f "$r/prev.bin" "$r/bin/misterplexd"
  echo 1 >"$r/state/n_daemon"
  md5sum "$r/bin/misterplexd" | awk '{print $1}' >"$r/state/live_md5"
  echo 200 >"$r/state/http"
  echo 1 >"$r/state/started_after_restore"
  printf 'DECODE=624x480\nPRESENT=fpga\n' >"$r/misterplex.conf"
}

# GREEN baseline
setup_root "$DIR/root_ok"
run_capture pc_green env \
  RESTORE_ROOT="$DIR/root_ok" \
  RESTORE_PREV="$DIR/root_ok/prev.bin" \
  RESTORE_STATE="$DIR/root_ok/state" \
  RESTORE_EXPECT_GEOM=480 \
  "$PC"
expect_rc pc_green 0 "healthy restore postconditions"

# R3 FIRST: installed bytes differ from PREV (discarded md5 class)
setup_root "$DIR/root_r3"
printf 'DIFFERENT-BYTES-not-prev\n' >"$DIR/root_r3/bin/misterplexd"
md5sum "$DIR/root_r3/bin/misterplexd" | awk '{print $1}' >"$DIR/root_r3/state/live_md5"
run_capture pc_r3 env \
  RESTORE_ROOT="$DIR/root_r3" \
  RESTORE_PREV="$DIR/root_r3/prev.bin" \
  RESTORE_STATE="$DIR/root_r3/state" \
  RESTORE_EXPECT_GEOM=480 \
  "$PC"
expect_nonzero pc_r3 "R3 installed md5 != PREV must fail"
st=$(cat "$DIR/pc_r3.rc")
[[ "$st" -eq 5 ]] && echo "PASS pc_r3 exact rc=5" || echo "NOTE pc_r3 rc=$st (nonzero required)"

# R5 FIRST: wrong geometry, daemon otherwise healthy — GUARANTEED pass without geometry gate
setup_root "$DIR/root_r5"
printf 'DECODE=320x240\nPRESENT=fpga\n' >"$DIR/root_r5/misterplex.conf"
run_capture pc_r5 env \
  RESTORE_ROOT="$DIR/root_r5" \
  RESTORE_PREV="$DIR/root_r5/prev.bin" \
  RESTORE_STATE="$DIR/root_r5/state" \
  RESTORE_EXPECT_GEOM=480 \
  "$PC"
expect_nonzero pc_r5 "R5 DECODE 240 vs expect 480 must fail (broken picture)"
st=$(cat "$DIR/pc_r5.rc")
[[ "$st" -eq 8 ]] && echo "PASS pc_r5 exact rc=8" || echo "NOTE pc_r5 rc=$st"

# R1: delete PREV
setup_root "$DIR/root_r1"
rm -f "$DIR/root_r1/prev.bin"
run_capture pc_r1 env \
  RESTORE_ROOT="$DIR/root_r1" \
  RESTORE_PREV="$DIR/root_r1/prev.bin" \
  RESTORE_STATE="$DIR/root_r1/state" \
  "$PC"
expect_nonzero pc_r1 "R1 missing PREV"

# R2: truncate PREV to 0
setup_root "$DIR/root_r2"
: >"$DIR/root_r2/prev.bin"
run_capture pc_r2 env \
  RESTORE_ROOT="$DIR/root_r2" \
  RESTORE_PREV="$DIR/root_r2/prev.bin" \
  RESTORE_STATE="$DIR/root_r2/state" \
  "$PC"
expect_nonzero pc_r2 "R2 empty PREV"

# R4: HTTP refuse (supervisor/health)
setup_root "$DIR/root_r4"
echo 000 >"$DIR/root_r4/state/http"
run_capture pc_r4 env \
  RESTORE_ROOT="$DIR/root_r4" \
  RESTORE_PREV="$DIR/root_r4/prev.bin" \
  RESTORE_STATE="$DIR/root_r4/state" \
  "$PC"
expect_nonzero pc_r4 "R4 HTTP not healthy"

# R6: old daemon never replaced
setup_root "$DIR/root_r6"
echo 0 >"$DIR/root_r6/state/started_after_restore"
run_capture pc_r6 env \
  RESTORE_ROOT="$DIR/root_r6" \
  RESTORE_PREV="$DIR/root_r6/prev.bin" \
  RESTORE_STATE="$DIR/root_r6/state" \
  "$PC"
expect_nonzero pc_r6 "R6 started_after_restore=0"

# dead n_daemon
setup_root "$DIR/root_dead"
echo 0 >"$DIR/root_dead/state/n_daemon"
run_capture pc_dead env \
  RESTORE_ROOT="$DIR/root_dead" \
  RESTORE_PREV="$DIR/root_dead/prev.bin" \
  RESTORE_STATE="$DIR/root_dead/state" \
  "$PC"
expect_nonzero pc_dead "n_daemon=0"

echo "=== DEPLOY mutations (fake transport) ==="
SCRIPT="$ROOT/scripts/deploy_misterplexd.sh"
# Reuse structure from test_deploy_misterplexd.sh
WORK="$DIR/deploy"
mkdir -p "$WORK/state"
printf 'fake-misterplexd-mutation\n' >"$WORK/fake.bin"
chmod +x "$WORK/fake.bin"
HOST_MD5=$(md5sum "$WORK/fake.bin" | awk '{print $1}')
STATE="$WORK/state"
echo "v2" >"$STATE/live_root"
echo "1" >"$STATE/n_after"
echo "$HOST_MD5" >"$STATE/live_md5"
echo "$HOST_MD5" >"$STATE/disk_md5"
echo "200" >"$STATE/http"

# Minimal fake ssh/scp (same contract as test_deploy_misterplexd)
cat >"$WORK/fake_sshm.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${DEPLOY_FAKE_STATE:?}"
input="$(cat || true)"
args="$*"
if echo "$input" | grep -q 'DEPLOY_RESTART_VERIFY\|POST_N_DAEMON=\|DEPLOY_OK root='; then
  for tok in $args; do
    case "$tok" in
      TARGET_ROOT=*) echo "${tok#TARGET_ROOT=}" >"$STATE_DIR/chosen_root" ;;
      HOST_MD5=*) echo "${tok#HOST_MD5=}" >"$STATE_DIR/host_md5_seen" ;;
      REMOTE_BIN=*) echo "${tok#REMOTE_BIN=}" >"$STATE_DIR/remote_bin" ;;
    esac
  done
  n=$(cat "$STATE_DIR/n_after")
  md=$(cat "$STATE_DIR/live_md5")
  disk=$(cat "$STATE_DIR/disk_md5")
  http=$(cat "$STATE_DIR/http")
  chosen=$(cat "$STATE_DIR/chosen_root" 2>/dev/null || echo "")
  host=$(cat "$STATE_DIR/host_md5_seen" 2>/dev/null || true)
  rbin=$(cat "$STATE_DIR/remote_bin" 2>/dev/null || echo "$chosen/bin/misterplexd")
  conf="${chosen}/misterplex.conf"
  echo "REMOTE_DISK_MD5=$disk"
  echo "POST_N_DAEMON=$n"
  echo "POST_PIDS=99"
  echo "POST_LIVE_EXE=$rbin"
  echo "POST_LIVE_MD5=$md"
  echo "POST_LIVE_CONF=$conf"
  echo "POST_DISK_MD5=$disk"
  echo "POST_HOST_MD5=$host"
  echo "POST_TARGET_ROOT=$chosen"
  echo "POST_HTTP=$http"
  if [[ "$disk" != "$host" ]]; then echo "FAIL disk"; exit 5; fi
  if [[ "$n" -ne 1 ]]; then echo "FAIL n_daemon=$n want=1"; exit 3; fi
  if [[ "$md" != "$host" ]]; then echo "FAIL live exe md5"; exit 5; fi
  if [[ "$http" != "200" ]]; then echo "FAIL http $http"; exit 7; fi
  echo "DEPLOY_OK root=$chosen"; exit 0
fi
if echo "$input" | grep -q 'DEPLOY_LIVE_PROBE'; then
  root=/media/fat/misterplex_v2
  md=$(cat "$STATE_DIR/live_md5" 2>/dev/null || echo old)
  echo "LIVE_PID=4242 EXE=$root/bin/misterplexd ROOT=$root CONF=$root/misterplex.conf LIVE_MD5=$md CMD=misterplexd"
  echo "N_DAEMON=1"; echo "ROOT=$root"; exit 0
fi
if echo "$input" | grep -q 'STOP_OK'; then echo STOP_OK; exit 0; fi
if echo "$args" | grep -q 'md5sum'; then echo "$(cat "$STATE_DIR/disk_md5")  remote"; exit 0; fi
if echo "$input" | grep -q 'DEPLOY_INSTALL_PREP'; then echo MKDIR_OK; exit 0; fi
echo "FAKE_SSH unhandled" >&2; exit 99
FAKE
chmod +x "$WORK/fake_sshm.sh"
cat >"$WORK/fake_scpm.sh" <<'FAKE'
#!/usr/bin/env bash
cp -f "$1" "${DEPLOY_FAKE_STATE}/last_payload" 2>/dev/null || true
exit 0
FAKE
chmod +x "$WORK/fake_scpm.sh"

run_deploy() {
  local name="$1"
  set +e
  DEPLOY_FAKE_STATE="$STATE" \
  DEPLOY_SSHM="$WORK/fake_sshm.sh" \
  DEPLOY_SCPM="$WORK/fake_scpm.sh" \
  DEPLOY_REBUILD=0 DEPLOY_SKIP_GEOMETRY_GATE=1 DEPLOY_SKIP_BOOT_HOOK=1 \
  "$SCRIPT" "$WORK/fake.bin" >"$DIR/${name}.out" 2>&1
  echo $? >"$DIR/${name}.rc"
  set -e
  echo "${name} true rc=$(cat "$DIR/${name}.rc")"
}

# D0 green control
echo "1" >"$STATE/n_after"
echo "$HOST_MD5" >"$STATE/live_md5"
echo "$HOST_MD5" >"$STATE/disk_md5"
echo "200" >"$STATE/http"
run_deploy deploy_green
expect_rc deploy_green 0 "control green deploy"

# D1 DEAD DAEMON (parent-proven class) — n_after=0
echo "0" >"$STATE/n_after"
run_deploy deploy_dead
expect_nonzero deploy_dead "dead daemon n_daemon=0 must not exit 0"
st=$(cat "$DIR/deploy_dead.rc")
[[ "$st" -eq 1 || "$st" -eq 3 ]] && echo "PASS deploy_dead rc in {1,3} got=$st" || echo "NOTE deploy_dead rc=$st"

# D2 HTTP fail
echo "1" >"$STATE/n_after"
echo "000" >"$STATE/http"
run_deploy deploy_http
expect_nonzero deploy_http "HTTP not 200"

# D3 live md5 mismatch (disk-only)
echo "200" >"$STATE/http"
echo "ffffffffffffffffffffffffffffffff" >"$STATE/live_md5"
echo "$HOST_MD5" >"$STATE/disk_md5"
run_deploy deploy_diskonly
expect_nonzero deploy_diskonly "live md5 != host (ETXTBSY class)"

# restore green md5 state
echo "$HOST_MD5" >"$STATE/live_md5"

echo "=== OVERLAY blank-panel mutation (must not invent PAUSED) ==="
if command -v python3 >/dev/null && python3 -c 'from PIL import Image' 2>/dev/null; then
  python3 - <<'PY' "$DIR"
from PIL import Image
from pathlib import Path
import sys
d = Path(sys.argv[1])
im = Image.new("RGB", (640, 480), (230, 230, 200))
im.save(d / "blank_bright.png")
PY
  set +e
  python3 "$ROOT/tools/readback_overlay_text.py" \
    --image "$DIR/blank_bright.png" --expect PAUSED \
    >"$DIR/overlay_blank.out" 2>&1
  echo $? >"$DIR/overlay_blank.rc"
  set -e
  echo "overlay_blank true rc=$(cat "$DIR/overlay_blank.rc")"
  # Must NOT exit 0 with recovered=PAUSED
  if grep -q "recovered=PAUSED" "$DIR/overlay_blank.out" && [[ $(cat "$DIR/overlay_blank.rc") -eq 0 ]]; then
    echo "FINDING overlay_blank: invented PAUSED from blank bright panel"
    FINDINGS=$((FINDINGS + 1))
    FAIL=$((FAIL + 1))
  else
    echo "PASS overlay_blank: no false PAUSED PASS (rc=$(cat "$DIR/overlay_blank.rc"))"
  fi
  # recovered must not be PAUSED at all on blank
  if grep -qE 'recovered=PAUSED' "$DIR/overlay_blank.out"; then
    echo "FINDING overlay_blank: recovered=PAUSED printed on blank (even if rc!=0)"
    FINDINGS=$((FINDINGS + 1))
    FAIL=$((FAIL + 1))
    cat "$DIR/overlay_blank.out" | sed 's/^/  /'
  fi
else
  echo "SKIP overlay_blank: Pillow not available"
fi

echo "=== define-parity T7 mutation (already gated) ==="
set +e
python3 "$ROOT/scripts/check_define_parity.py" --fault-strip-t7-native \
  >"$DIR/defpar_t7.out" 2>&1
echo $? >"$DIR/defpar_t7.rc"
set -e
echo "defpar_t7 true rc=$(cat "$DIR/defpar_t7.rc")"
expect_nonzero defpar_t7 "T7 strip must red define-parity"

echo "=== soak continuity model port ==="
if [[ -f "$ROOT/tests/unit/test_soak_continuity_assert.sh" ]]; then
  set +e
  bash "$ROOT/tests/unit/test_soak_continuity_assert.sh" >"$DIR/soak.out" 2>&1
  echo $? >"$DIR/soak.rc"
  set -e
  echo "soak_continuity true rc=$(cat "$DIR/soak.rc")"
  expect_rc soak 0 "soak continuity red/green harness"
else
  echo "FAIL soak harness missing"; FAIL=$((FAIL + 1))
fi

echo
echo "=== summary FAIL=$FAIL FINDINGS=$FINDINGS work=$DIR ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "test_deploy_restore_mutations: FAIL"
  exit 1
fi
echo "test_deploy_restore_mutations: OK"
exit 0
