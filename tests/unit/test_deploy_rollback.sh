#!/usr/bin/env bash
# Discriminating proof: backup → install candidate → restore is byte-identical,
# and mid-copy abort leaves the live binary untouched.
# Local fixture only — no device, no SSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib_misterplexd_fs.sh
source "$ROOT/scripts/lib_misterplexd_fs.sh"

WORK="$ROOT/build/test_deploy_rollback_work"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/backup" "$WORK/incoming"

# Two distinct stand-in binaries (content, not necessarily ARM).
printf 'ORIGINAL-DAEMON-BYTES-v1-%s\n' "$(printf 'A%.0s' {1..200})" >"$WORK/bin/misterplexd"
printf 'CANDIDATE-DAEMON-BYTES-v2-%s\n' "$(printf 'B%.0s' {1..200})" >"$WORK/incoming/misterplexd"
printf 'PRESENT=fpga\nDECODE=320x240\n' >"$WORK/misterplex.conf"
chmod +x "$WORK/bin/misterplexd" "$WORK/incoming/misterplexd"

ORIG_MD5=$(md5sum "$WORK/bin/misterplexd" | awk '{print $1}')
CAND_MD5=$(md5sum "$WORK/incoming/misterplexd" | awk '{print $1}')
echo "orig_md5=$ORIG_MD5 cand_md5=$CAND_MD5"
if [[ "$ORIG_MD5" == "$CAND_MD5" ]]; then
  echo "FAIL: fixture binaries not distinct" >&2
  exit 1
fi

LIVE="$WORK/bin/misterplexd"
PREV="$WORK/bin/misterplexd.prev-c2"
CONF="$WORK/misterplex.conf"
BDIR="$WORK/backup"

# 1) Snapshot pair (pre-deploy)
mpx_snapshot_pair "$LIVE" "$CONF" "$BDIR" "before-test"
SNAP="$BDIR/misterplexd.before-test"
[[ -f "$SNAP" ]] || { echo "FAIL: snapshot missing"; exit 1; }
[[ "$(md5sum "$SNAP" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: snapshot md5 != orig"; exit 1
}
echo "PASS snapshot pair"

# 2) Deploy path: backup atomic then install candidate
mpx_backup_daemon_atomic "$LIVE" "$PREV"
[[ "$(md5sum "$PREV" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: prev-c2 md5 != orig after backup"; exit 1
}
mpx_install_daemon_atomic "$WORK/incoming/misterplexd" "$LIVE"
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$CAND_MD5" ]] || {
  echo "FAIL: live not candidate after install"; exit 1
}
echo "PASS backup+install"

# 3) Restore from prev-c2 → must be byte-identical to original
out=$(mpx_restore_daemon_atomic "$PREV" "$LIVE")
echo "$out"
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: restore from prev not byte-identical to orig"; exit 1
}
echo "PASS restore prev-c2 byte-identical"

# 4) Restore from named snapshot path (PREV_BIN override style)
mpx_install_daemon_atomic "$WORK/incoming/misterplexd" "$LIVE"
mpx_restore_daemon_atomic "$SNAP" "$LIVE" >/dev/null
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: restore from snapshot not identical"; exit 1
}
echo "PASS restore named snapshot byte-identical"

# 5) Mid-copy failure must not mutate live (install aborted after partial stage)
mpx_install_daemon_atomic "$WORK/incoming/misterplexd" "$LIVE"
# live is candidate; restore orig first for clean mid-fail base
mpx_restore_daemon_atomic "$PREV" "$LIVE" >/dev/null
mpx_simulate_mid_copy_fail "$WORK/incoming/misterplexd" "$LIVE"
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: mid-copy simulation mutated live"; exit 1
}
echo "PASS mid-copy abort leaves live intact"

# 6) Partial-fail recovery: live missing, only prev remains → restore works
rm -f "$LIVE"
[[ ! -f "$LIVE" ]] || { echo "FAIL: could not remove live"; exit 1; }
mpx_restore_daemon_atomic "$PREV" "$LIVE" >/dev/null
[[ -f "$LIVE" ]] || { echo "FAIL: restore did not recreate live"; exit 1; }
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$ORIG_MD5" ]] || {
  echo "FAIL: hole-recovery restore md5 wrong"; exit 1
}
echo "PASS restore when live binary missing (mid-deploy hole)"

# 7) Conf-written-but-binary-not: conf snapshot still available
printf 'PRESENT=fb0\nBROKEN=1\n' >"$CONF"
# "deploy" conf-only damage; binary still orig
[[ "$(md5sum "$LIVE" | awk '{print $1}')" == "$ORIG_MD5" ]]
cp -f "$BDIR/misterplex.conf.before-test" "$CONF"
grep -q 'PRESENT=fpga' "$CONF" || { echo "FAIL: conf restore"; exit 1; }
grep -q 'BROKEN' "$CONF" && { echo "FAIL: broken conf remained"; exit 1; }
echo "PASS conf restore from snapshot"

# 8) Fail-closed: md5 mismatch → rc=2 (restore must not claim success)
printf 'CORRUPT\n' >"$LIVE"
set +e
mpx_require_md5_equal "$PREV" "$LIVE" >/dev/null 2>"$WORK/md5.err"
md5_rc=$?
set -e
echo "md5_mismatch_rc=$md5_rc"
[[ "$md5_rc" -eq 2 ]] || { echo "FAIL: md5 mismatch want rc=2 got $md5_rc"; exit 1; }
grep -q 'RESTORE_FAIL: md5 mismatch' "$WORK/md5.err" || {
  echo "FAIL: missing RESTORE_FAIL md5 diagnostic"; cat "$WORK/md5.err"; exit 1
}
echo "PASS md5 mismatch fail-closed rc=2"

# 9) Fail-closed: wrong --id → rc=7
set +e
mpx_require_ps_id '123 ./bin/misterplexd --id misterplex-wrong --port 3005' 'misterplex-dev' \
  >/dev/null 2>"$WORK/id.err"
id_rc=$?
set -e
echo "id_mismatch_rc=$id_rc"
[[ "$id_rc" -eq 7 ]] || { echo "FAIL: id mismatch want rc=7 got $id_rc"; exit 1; }
grep -q 'DAEMON_ID_MISMATCH' "$WORK/id.err" || {
  echo "FAIL: missing id diagnostic"; cat "$WORK/id.err"; exit 1
}
# good id must pass
mpx_require_ps_id '123 ./bin/misterplexd --id misterplex-dev --port 3005' 'misterplex-dev' >/dev/null
# prefix must not pass
set +e
mpx_require_ps_id '123 ./bin/misterplexd --id misterplex-dev-old --port 3005' 'misterplex-dev' >/dev/null 2>&1
pref_rc=$?
set -e
[[ "$pref_rc" -eq 7 ]] || { echo "FAIL: prefix id should rc=7 got $pref_rc"; exit 1; }
echo "PASS --id mismatch fail-closed rc=7 (prefix rejected)"

# 10) Full-size ARM binary cycle + wall time (if artifact present)
ARM_SRC="$ROOT/build/arm/misterplexd"
CAND_ARM="${CAND_ARM:-$ROOT/../w-arm-hybrid/build/arm/misterplexd}"
if [[ -f "$ARM_SRC" ]]; then
  mkdir -p "$WORK/full/bin" "$WORK/full/backup" "$WORK/full/incoming"
  cp -f "$ARM_SRC" "$WORK/full/bin/misterplexd"
  if [[ -f "$CAND_ARM" ]]; then
    cp -f "$CAND_ARM" "$WORK/full/incoming/misterplexd"
  else
    # distinct candidate: flip one byte
    cp -f "$ARM_SRC" "$WORK/full/incoming/misterplexd"
    printf '\xff' | dd of="$WORK/full/incoming/misterplexd" bs=1 seek=4096 conv=notrunc status=none
  fi
  FULL_ORIG=$(md5sum "$WORK/full/bin/misterplexd" | awk '{print $1}')
  FULL_CAND=$(md5sum "$WORK/full/incoming/misterplexd" | awk '{print $1}')
  [[ "$FULL_ORIG" != "$FULL_CAND" ]] || { echo "FAIL: full-size orig==cand"; exit 1; }
  t0=$(date +%s%N)
  mpx_backup_daemon_atomic "$WORK/full/bin/misterplexd" "$WORK/full/bin/misterplexd.prev-c2"
  mpx_install_daemon_atomic "$WORK/full/incoming/misterplexd" "$WORK/full/bin/misterplexd"
  [[ "$(md5sum "$WORK/full/bin/misterplexd" | awk '{print $1}')" == "$FULL_CAND" ]]
  mpx_restore_daemon_atomic "$WORK/full/bin/misterplexd.prev-c2" "$WORK/full/bin/misterplexd" >/dev/null
  [[ "$(md5sum "$WORK/full/bin/misterplexd" | awk '{print $1}')" == "$FULL_ORIG" ]]
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  echo "full_size_orig=$FULL_ORIG cand=$FULL_CAND cycle_ms=$ms size=$(wc -c <"$WORK/full/bin/misterplexd")"
  echo "PASS full-size ARM binary backup/install/restore byte-identical (${ms}ms local fs)"
else
  echo "SKIP full-size ARM cycle (no build/arm/misterplexd)"
fi

echo "OK deploy rollback local e2e (byte-identical + mid-fail + hole + fail-closed)"
