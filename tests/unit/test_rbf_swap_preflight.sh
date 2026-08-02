#!/usr/bin/env bash
# Host-side both-direction tests for rbf_swap_preflight (no device).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

SCR="$ROOT/scripts/rbf_swap_preflight.sh"
[[ -x "$SCR" ]] || { echo "missing $SCR"; exit 2; }
bash -n "$SCR" || { echo "bash -n fail"; exit 2; }
pass bash-n

# min-postcond lists HARD set
out=$("$SCR" min-postcond 2>&1); rc=$?
echo "min-postcond true rc=$rc"
[[ "$rc" -eq 0 ]] && pass min-rc0 || fail min-rc0 "rc=$rc"
echo "$out" | grep -q 'H1 n_daemon' && pass min-h1 || fail min-h1 missing
echo "$out" | grep -q 'H2 live_exe_md5' && pass min-h2 || fail min-h2 missing
echo "$out" | grep -q 'H3 core_path_md5' && pass min-h3 || fail min-h3 missing
echo "$out" | grep -q 'H4 pair_policy' && pass min-h4 || fail min-h4 missing
echo "$out" | grep -q 'H5 HTTP' && pass min-h5 || fail min-h5 missing
echo "$out" | grep -q 'H6 conf_md5' && pass min-h6 || fail min-h6 missing
echo "$out" | grep -q 'H7 PRESENT' && pass min-h7 || fail min-h7 missing
echo "$out" | grep -q 'S1 CORENAME' && pass soft-corename || fail soft-corename missing
echo "$out" | grep -qi 'USELESS\|SOFT' && pass corename-not-hard || fail corename-not-hard 'CORENAME must be soft'
echo "$out" | grep -qi 'frames_done\|vsync\|STALE' && pass c5382-note || fail c5382-note missing
echo "$out" | grep -qi 'drops=0\|ARM-supply\|unaccounted' && pass drops-void || fail drops-void missing
echo "$out" | grep -qi '240-row\|vertical' && pass vert-ceiling || fail vert-ceiling missing
echo "$out" | grep -qi 'STANDING RULE\|derivation' && pass field-rule || fail field-rule missing

# plan dry
out=$("$SCR" plan 2>&1); rc=$?
echo "plan true rc=$rc"
[[ "$rc" -eq 0 ]] && pass plan-rc0 || fail plan-rc0 "rc=$rc"
echo "$out" | grep -q 'DEPLOY_LOAD=none' && pass plan-none || fail plan-none missing
echo "$out" | grep -q 'DEPLOY_LOAD=menu' && pass plan-menu || fail plan-menu missing
echo "$out" | grep -q 'rollback_v2' && pass plan-rollback || fail plan-rollback missing

# banned NEW_RBF => non-zero (dir-red)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'fake-rbf' >"$TMP/bad.rbf"
# force md5 prefix by writing known content won't work — call policy via env wrapping
# Use a tiny helper: create file, then override check by running rbf_policy with known banned
# shellcheck source=/dev/null
source "$ROOT/scripts/rbf_ship_policy.sh"
set +e
rbf_policy_check_md5 8832824e000000000000000000000000 >/dev/null
brc=$?
set -e
echo "banned-policy true rc=$brc"
[[ "$brc" -ne 0 ]] && pass banned-red || fail banned-red "rc=$brc want!=0"

# green ship policy on a non-banned synthetic md5 (c5382bee is allowed product pin)
set +e
rbf_policy_check_md5 c5382bee73cecdee8220b811e529c297 >/dev/null
grc=$?
set -e
echo "c5382-policy true rc=$grc"
[[ "$grc" -eq 0 ]] && pass c5382-green-policy || fail c5382-green-policy "rc=$grc"

# snapshot dry (EXECUTE=0) rc0
out=$(PREFLIGHT_EXECUTE=0 "$SCR" snapshot 2>&1); rc=$?
echo "snapshot-dry true rc=$rc"
[[ "$rc" -eq 0 ]] && pass snap-dry || fail snap-dry "rc=$rc"
echo "$out" | grep -q PREFLIGHT_SNAPSHOT_BEGIN && pass snap-script || fail snap-script missing

# verify-rollback dry needs SNAP with pins.env
mkdir -p "$TMP/snap"
cat >"$TMP/snap/pins.env" <<'E'
PRE_N_DAEMON=1
PRE_LIVE_DAEMON_MD5=36b89bcb87399f4681fd41ddd226e5b4
PRE_CONF_MD5=7f06132f0c00e90b35141bdc0c60ccc9
PRE_HTTP=200
PRE_PRESENT=fpga
E
out=$(PREFLIGHT_EXECUTE=0 SNAP="$TMP/snap" "$SCR" verify-rollback 2>&1); rc=$?
echo "verify-dry true rc=$rc"
[[ "$rc" -eq 0 ]] && pass verify-dry || fail verify-dry "rc=$rc"
echo "$out" | grep -q 'H1 n_daemon' && pass verify-lists-h || fail verify-lists-h missing

# verify-rollback EXECUTE with mock ssh — GREEN direction
mock_ok="$TMP/mock_ssh_ok.sh"
cat >"$mock_ok" <<'M'
#!/usr/bin/env bash
cat <<'BLOB'
PREFLIGHT_SNAPSHOT_BEGIN
LIVE_PID=1
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=abcdef0123456789abcdef0123456789
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
N_DAEMON=1
PIDS= 1
CORE_MD5 /media/fat/_Utility/Plex_v2.rbf dfebf2bfd08dd70b473b587dd7e81848
CORENAME=Plex
CONF_PATH_FROM_CMDLINE=/media/fat/misterplex_v2/misterplex.conf
CONF_MD5=7f06132f0c00e90b35141bdc0c60ccc9
CONF_BODY_BEGIN
PRESENT=fpga
IDLE_SCREEN=logo
CONF_BODY_END
PRESENT=fpga
IDLE_SCREEN=logo
HTTP_RESOURCES=200
PREFLIGHT_SNAPSHOT_END
BLOB
M
chmod +x "$mock_ok"
out=$(PREFLIGHT_EXECUTE=1 PREFLIGHT_SSHM="$mock_ok" SNAP="$TMP/snap" \
  EXPECT_DAEMON_MD5=abcdef0123456789abcdef0123456789 \
  EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \
  "$SCR" verify-rollback 2>&1); rc=$?
echo "verify-green true rc=$rc"
echo "$out" | tail -8
[[ "$rc" -eq 0 ]] && pass verify-green || fail verify-green "rc=$rc"
echo "$out" | grep -q VERIFY_ROLLBACK_OK && pass verify-ok-msg || fail verify-ok-msg missing

# RED: n_daemon=2
mock_bad="$TMP/mock_ssh_bad.sh"
cat >"$mock_bad" <<'M'
#!/usr/bin/env bash
cat <<'BLOB'
PREFLIGHT_SNAPSHOT_BEGIN
LIVE_PID=1
LIVE_MD5=deadbeefdeadbeefdeadbeefdeadbeef
N_DAEMON=2
CORE_MD5 /media/fat/_Utility/Plex.rbf c5382bee73cecdee8220b811e529c297
CONF_MD5=00000000000000000000000000000000
PRESENT=fb0
HTTP_RESOURCES=000
PREFLIGHT_SNAPSHOT_END
BLOB
M
chmod +x "$mock_bad"
set +e
out=$(PREFLIGHT_EXECUTE=1 PREFLIGHT_SSHM="$mock_bad" SNAP="$TMP/snap" \
  EXPECT_DAEMON_MD5=abcdef0123456789abcdef0123456789 \
  EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \
  "$SCR" verify-rollback 2>&1); rc=$?
set -e
echo "verify-red true rc=$rc"
echo "$out" | tail -12
[[ "$rc" -ne 0 ]] && pass verify-red || fail verify-red "rc=$rc want!=0"
echo "$out" | grep -q VERIFY_ROLLBACK_FAIL && pass verify-fail-msg || fail verify-fail-msg missing
echo "$out" | grep -q 'FAIL H1' && pass red-h1 || fail red-h1 missing
echo "$out" | grep -q 'FAIL H5' && pass red-h5 || fail red-h5 missing
echo "$out" | grep -q 'FAIL H6' && pass red-h6 || fail red-h6 missing
echo "$out" | grep -q 'FAIL H7' && pass red-h7 || fail red-h7 missing

# missing SNAP => non-zero
set +e
out=$(PREFLIGHT_EXECUTE=0 SNAP="" "$SCR" verify-rollback 2>&1); rc=$?
set -e
echo "missing-snap true rc=$rc"
[[ "$rc" -ne 0 ]] && pass miss-snap || fail miss-snap "rc=$rc"

echo "=== summary pass=$PASS fail=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
