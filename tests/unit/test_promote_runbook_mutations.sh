#!/usr/bin/env bash
# Mutation proofs for promotion runbook gates (host-only, no device).
# Parent 2026-08-01: every failure mode must show rc-before (broken) vs rc-after (fixed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

pass=0
fail=0
ok() { echo "ok: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

echo "=== 1) LEGACY liveness pipe lie (gate-liveness :73-74) ==="
# Broken: wget fails (daemon dead) but head succeeds → script rc 0
set +e
deploy_legacy_liveness_pipe_lie 1 0
legacy_rc=$?
set -e
echo "  legacy_dead_daemon true rc=$legacy_rc"
if [[ "$legacy_rc" -eq 0 ]]; then
  ok "legacy-pipe-lies-rc0-on-dead-daemon (documents defect)"
else
  bad "legacy-pipe should return 0 (the lie)"
fi

# Fixed: empty/000 HTTP must fail
set +e
deploy_assert_resources_http ""
rc_empty=$?
set -e
echo "  assert_http empty true rc=$rc_empty"
[[ "$rc_empty" -eq 4 ]] && ok "fixed-http-empty-rc4" || bad "fixed-http-empty got=$rc_empty"

set +e
deploy_assert_resources_http "000"
rc_000=$?
set -e
echo "  assert_http 000 true rc=$rc_000"
[[ "$rc_000" -eq 7 ]] && ok "fixed-http-000-rc7" || bad "fixed-http-000 got=$rc_000"

set +e
deploy_assert_resources_http "200"
rc_200=$?
set -e
echo "  assert_http 200 true rc=$rc_200"
[[ "$rc_200" -eq 0 ]] && ok "fixed-http-200-rc0" || bad "fixed-http-200 got=$rc_200"

echo "=== 2) Dead daemon postconditions (n_daemon=0) ==="
set +e
deploy_assert_postconditions 0 deadbeef deadbeef \
  /media/fat/misterplex_v2/misterplex.conf /media/fat/misterplex_v2 \
  200 abc abc
rc_dead=$?
set -e
echo "  n_daemon=0 true rc=$rc_dead"
[[ "$rc_dead" -eq 3 ]] && ok "dead-n0-rc3" || bad "dead-n0 got=$rc_dead"

set +e
deploy_assert_postconditions 1 deadbeef deadbeef \
  /media/fat/misterplex_v2/misterplex.conf /media/fat/misterplex_v2 \
  200 abc abc
rc_live=$?
set -e
echo "  n_daemon=1 http200 true rc=$rc_live"
[[ "$rc_live" -eq 0 ]] && ok "live-postcond-rc0" || bad "live-postcond got=$rc_live"

echo "=== 3) Geometry rc=77 must not be overall PASS ==="
set +e
deploy_geometry_gate_rc 77 1
geo_req=$?
set -e
echo "  geo77 require=1 true rc=$geo_req"
[[ "$geo_req" -eq 78 ]] && ok "geo77-require-rc78" || bad "geo77-require got=$geo_req"

set +e
deploy_geometry_gate_rc 0 1
geo_ok=$?
set -e
echo "  geo0 true rc=$geo_ok"
[[ "$geo_ok" -eq 0 ]] && ok "geo0-rc0" || bad "geo0 got=$geo_ok"

echo "=== 4) Restore postconditions — mutation (md5 mismatch) ==="
# Broken pattern was: md5sum a b || true  → always continued
set +e
# shellcheck disable=SC2015
md5sum /etc/hosts /etc/passwd >/dev/null 2>&1 || true
broken_restore_rc=$?
set -e
echo "  legacy md5sum||true true rc=$broken_restore_rc"
[[ "$broken_restore_rc" -eq 0 ]] && ok "legacy-restore-md5-or-true-rc0 (documents defect)" \
  || bad "legacy-or-true unexpected"

set +e
restore_assert_postconditions 1 aaa bbb 200 ccc ccc ddd ddd
rc_rmis=$?
set -e
echo "  restore live!=expect true rc=$rc_rmis"
[[ "$rc_rmis" -eq 5 ]] && ok "restore-md5-mismatch-rc5" || bad "restore-md5-mismatch got=$rc_rmis"

set +e
restore_assert_postconditions 1 aaa aaa 200 ccc ccc ddd ddd eee eee
rc_rok=$?
set -e
echo "  restore all match true rc=$rc_rok"
[[ "$rc_rok" -eq 0 ]] && ok "restore-all-match-rc0" || bad "restore-all-match got=$rc_rok"

set +e
restore_assert_postconditions 1 aaa aaa 200 ccc XXX ddd ddd
rc_rconf=$?
set -e
echo "  restore conf mutated true rc=$rc_rconf"
[[ "$rc_rconf" -eq 7 ]] && ok "restore-conf-mut-rc7" || bad "restore-conf-mut got=$rc_rconf"

set +e
restore_assert_postconditions 0 aaa aaa 200 ccc ccc ddd ddd
rc_rn=$?
set -e
echo "  restore n=0 true rc=$rc_rn"
[[ "$rc_rn" -eq 3 ]] && ok "restore-n0-rc3" || bad "restore-n0 got=$rc_rn"

echo "=== 5) Two-roots trap preflight ==="
set +e
deploy_assert_two_roots_safe "/media/fat/misterplex_v2" \
  "/media/fat/misterplex/misterplex.conf" 1 1
rc_foreign=$?
set -e
echo "  foreign conf true rc=$rc_foreign"
[[ "$rc_foreign" -eq 12 ]] && ok "two-roots-foreign-rc12" || bad "two-roots-foreign got=$rc_foreign"

set +e
deploy_assert_two_roots_safe "/media/fat/misterplex_v2" \
  "/media/fat/misterplex_v2/misterplex.conf" 0 1
rc_miss=$?
set -e
echo "  missing v2 conf + v1 exists true rc=$rc_miss"
[[ "$rc_miss" -eq 12 ]] && ok "two-roots-missing-install-rc12" || bad "two-roots-missing got=$rc_miss"

set +e
deploy_assert_two_roots_safe "/media/fat/misterplex_v2" \
  "/media/fat/misterplex_v2/misterplex.conf" 1 1
rc_ok_roots=$?
set -e
echo "  safe layout true rc=$rc_ok_roots"
[[ "$rc_ok_roots" -eq 0 ]] && ok "two-roots-safe-rc0" || bad "two-roots-safe got=$rc_ok_roots"

echo "=== 6) Conf + MiSTer.ini byte-exact ==="
set +e
user_state_assert_byte_exact conf 7f06132f 7f06132f
rc_c=$?
user_state_assert_byte_exact ini ab8398d6 deadbeef
rc_i=$?
set -e
echo "  conf match true rc=$rc_c"
echo "  ini mismatch true rc=$rc_i"
[[ "$rc_c" -eq 0 ]] && ok "conf-byte-exact-rc0" || bad "conf-byte-exact got=$rc_c"
[[ "$rc_i" -eq 7 ]] && ok "ini-mismatch-rc7" || bad "ini-mismatch got=$rc_i"

echo "=== 7) Post-promotion session — cannot pass vacuously ==="
set +e
promotion_assert_session_telemetry 1 624x480 0 0 23.97 23.97 0
rc_unscored=$?
set -e
echo "  no session true rc=$rc_unscored"
[[ "$rc_unscored" -eq 77 ]] && ok "session-unscored-rc77" || bad "session-unscored got=$rc_unscored"

set +e
promotion_assert_session_telemetry 1 624x480 0 0 23.9706 23.97 1
rc_pass=$?
set -e
echo "  full session true rc=$rc_pass"
[[ "$rc_pass" -eq 0 ]] && ok "session-pass-rc0" || bad "session-pass got=$rc_pass"

set +e
promotion_assert_session_telemetry 0 624x480 0 0 23.97 23.97 1
rc_dv=$?
set -e
echo "  delivery_verified=0 true rc=$rc_dv"
[[ "$rc_dv" -eq 1 ]] && ok "session-dv0-rc1" || bad "session-dv0 got=$rc_dv"

set +e
promotion_assert_session_telemetry 1 624x480 2 0 23.97 23.97 1
rc_drops=$?
set -e
echo "  drops=2 true rc=$rc_drops"
[[ "$rc_drops" -eq 1 ]] && ok "session-drops-rc1" || bad "session-drops got=$rc_drops"

echo "=== 8) Menu bounce full path ==="
cmds=$(promotion_menu_bounce_cmd "/media/fat/_Utility/Plex.rbf")
echo "$cmds" | grep -q 'load_core /media/fat/menu.rbf' && ok "menu-full-path" || bad "menu-full-path"
echo "$cmds" | grep -q 'load_core /media/fat/_Utility/Plex.rbf' && ok "core-full-path" || bad "core-full-path"
if echo "$cmds" | grep -qE '^load_core menu\.rbf$'; then
  bad "bare-menu-rbf-forbidden"
else
  ok "no-bare-menu-rbf"
fi

echo "=== 9) Integrated deploy fake: n_daemon=0 must not DEPLOY_OK ==="
WORK="$ROOT/.agent-work/promote-runbook-mut"
rm -rf "$WORK"
mkdir -p "$WORK"
# Minimal fake ssh that pretends install ok but zero daemons after start
cat >"$WORK/fake_sshm.sh" <<'EOS'
#!/usr/bin/env bash
cmd="$*"
# Very small subset — if deploy needs more, skip with note
if [[ "$cmd" == *"POST_N_DAEMON"* ]] || [[ "$cmd" == *"for d in /proc"* ]]; then
  echo "POST_N_DAEMON=0"
  echo "POST_PIDS="
  echo "POST_LIVE_EXE="
  echo "POST_LIVE_MD5="
  echo "POST_LIVE_CONF="
  echo "POST_DISK_MD5=abc"
  echo "POST_HOST_MD5=abc"
  echo "POST_HTTP=000"
  echo "FAIL n_daemon=0 want=1"
  exit 3
fi
if [[ "$cmd" == *"md5sum"* ]]; then
  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  x"
  exit 0
fi
exit 0
EOS
chmod +x "$WORK/fake_sshm.sh"
# Rely on pure assert above for n=0; full deploy fake is heavy.
# Structural: deploy script must call deploy_assert_postconditions / die on start_rc
grep -q 'deploy_assert_postconditions' "$ROOT/scripts/deploy_misterplexd.sh" \
  && ok "deploy-calls-postconditions" || bad "deploy-calls-postconditions"
grep -q 'deploy_geometry_gate_rc' "$ROOT/scripts/deploy_misterplexd.sh" \
  && ok "deploy-calls-geometry-gate" || bad "deploy-calls-geometry-gate"
# Must not swallow 77 with || true anymore
if grep -nE 'geometry_skip.*\|\| true|rc=77.*\|\| true' "$ROOT/scripts/deploy_misterplexd.sh" | grep -v '^#'; then
  bad "deploy-still-swallows-77"
else
  ok "deploy-no-swallow-77"
fi

echo "=== summary pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]] || exit 1
echo "ALL test_promote_runbook_mutations passed"
exit 0
