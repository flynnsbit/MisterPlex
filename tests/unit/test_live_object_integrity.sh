#!/usr/bin/env bash
# Host-only RBG for live-object / decoy / unreachable-branch family.
# Fixtures: tests/fixtures/gate_integrity/
# Never touches the device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$ROOT/tests/fixtures/gate_integrity"
BOOT="$FIX/boot"
GATES="$ROOT/scripts/promotion_gate_check.sh"
HOOK="$ROOT/scripts/boot_hook_policy.sh"
VIS="$ROOT/scripts/pair_visual_gate.sh"
WORK="$ROOT/build/live-object-integrity"
rm -rf "$WORK"
mkdir -p "$WORK"
# shellcheck source=boot_hook_policy.sh
source "$HOOK"
# shellcheck source=live_object.inc.sh
source "$ROOT/scripts/live_object.inc.sh"

bash -n "$HOOK"
bash -n "$GATES"
bash -n "$VIS"
bash -n "$ROOT/scripts/live_object.inc.sh"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

V2=/media/fat/misterplex_v2

echo "=== PATH constants: LIVE is user-startup.sh (no underscore) ==="
echo "  BOOT_HOOK_DEVICE_PATH=$BOOT_HOOK_DEVICE_PATH"
echo "  BOOT_HOOK_DECOY_PATH=$BOOT_HOOK_DECOY_PATH"
[[ "$BOOT_HOOK_DEVICE_PATH" == *'/user-startup.sh' ]] && [[ "$BOOT_HOOK_DEVICE_PATH" != *'_user-startup.sh' ]] \
  && ok "live-path-no-underscore" || bad "live-path-no-underscore got=$BOOT_HOOK_DEVICE_PATH"
[[ "$BOOT_HOOK_DECOY_PATH" == *'/_user-startup.sh' ]] && ok "decoy-path-underscore" || bad "decoy-path"

echo "=== RED: archived bak v1 LIVE body (parent _user-startup.sh.bak.20260731T204811Z class) ==="
set +e
out=$("$HOOK" check "$BOOT/_user-startup.sh.bak.20260731T204811Z" "$V2" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
[ "$rc" -ne 0 ] && ok "bak-v1-red" || bad "bak-v1-red should not pass"
echo "$out" | grep -qiE 'mismatch|v1_hook|expect|BOOT_HOOK_FAIL' && ok "bak-v1-msg" || bad "bak-v1-msg"

echo "=== RED: decoy OK + LIVE bad (INSTANCE 1 the decoy file) ==="
set +e
out=$("$HOOK" check-live-decoy \
  "$BOOT/user-startup.sh.LIVE" \
  "$BOOT/_user-startup.sh.DECOY" \
  "$V2" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
[ "$rc" -ne 0 ] && ok "decoy-ok-live-bad-red" || bad "decoy-ok-live-bad-red"
echo "$out" | grep -qi 'decoy_ok_live_bad\|decoy_not_live\|LIVE' && ok "decoy-class-msg" || bad "decoy-class-msg"
# Decoy alone would be GREEN — prove that
set +e
out=$("$HOOK" check "$BOOT/_user-startup.sh.DECOY" "$V2" 2>&1)
drc=$?
set -e
echo "  decoy-alone true rc=$drc"
[ "$drc" -eq 0 ] && ok "decoy-alone-green-trap" || bad "decoy-alone-green-trap (fixture must be v2-good)"

echo "=== GREEN: LIVE v2 body via check-live-decoy ==="
good=$(boot_hook_line_for_root "$V2")
printf '%s\n' "$good" >"$WORK/live_good.hook"
printf '%s\n' "$good" >"$WORK/decoy_good.hook"
set +e
out=$("$HOOK" check-live-decoy "$WORK/live_good.hook" "$WORK/decoy_good.hook" "$V2" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "live-decoy-both-good" || bad "live-decoy-both-good rc=$rc"
echo "$out" | grep -q 'BOOT_HOOK_LIVE_OK\|BOOT_HOOK_OK' && ok "live-ok-marker" || bad "live-ok-marker"

echo "=== RED: MENU postboot.png must NOT pass idle envelope ==="
set +e
out=$(PAIR_IDLE_PNG="$FIX/postboot_menu.png" "$VIS" idle 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /' | tail -20
echo "  postboot true rc=$rc"
[ "$rc" -ne 0 ] && ok "menu-postboot-red" || bad "menu-postboot-red still green"
echo "$out" | grep -qiE 'menu_color_bars|VISUAL_FAIL|FAIL class' && ok "menu-class-msg" || bad "menu-class-msg"

echo "=== RED: conf-keys NOTE-without-rc is now FAIL ==="
cat >"$WORK/live.blob" <<BLOB
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=c5382bee73cecdee8220b811e529c297
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=dfebf2bfd08dd70b473b587dd7e81848
N_DAEMON=1
PIDS=1
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=edc3a46b9d1c6b86337deb90f896eb0f
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_ROOT=/media/fat/misterplex_v2
BLOB
cat >"$WORK/http.sh" <<'H'
#!/usr/bin/env bash
echo 200
H
chmod +x "$WORK/http.sh"
cat >"$WORK/vis.sh" <<'V'
#!/usr/bin/env bash
exit 0
V
chmod +x "$WORK/vis.sh"
printf '%s\n' "$good" >"$WORK/good.hook"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  env -u PROMOTE_CONF_BLOB -u PROMOTE_CONF_PATH \
  PROMOTE_REQUIRE_CONF_KEYS=1 \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [conf] /' | tail -15
echo "  [conf] true rc=$rc"
[ "$rc" -ne 0 ] && ok "conf-keys-fail-closed" || bad "conf-keys-fail-closed"
echo "$out" | grep -q 'FAIL conf-keys' && ok "conf-keys-msg" || bad "conf-keys-msg"

echo "=== RED: gate blob without hook fails (not NOTE) ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  env -u PROMOTE_HOOK_BLOB -u PROMOTE_HOOK_BODY \
  PROMOTE_REQUIRE_BOOT_HOOK=0 \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
# Create conf for this and next tests
cat >"$WORK/conf_ddr.txt" <<'C'
DDR_YUV_FORCE_SCALE=1
FFMPEG_SWS_FLAGS=fast_bilinear
C
# re-run with conf after creating file
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  env -u PROMOTE_HOOK_BLOB -u PROMOTE_HOOK_BODY \
  PROMOTE_REQUIRE_BOOT_HOOK=0 \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [nohook] /' | tail -12
echo "  [nohook] true rc=$rc"
[ "$rc" -ne 0 ] && ok "nohook-fail" || bad "nohook-fail"
echo "$out" | grep -qi 'boot-hook' && ok "nohook-msg" || bad "nohook-msg"

echo "=== motion NOT dead behind idle (INSTANCE 2) ==="
cat >"$WORK/motion0.sh" <<'M'
#!/usr/bin/env bash
echo "VERDICT=MOTION_OK"
echo "MOTION_RAN=1"
exit 0
M
chmod +x "$WORK/motion0.sh"
# Provide BOTH idle png (MENU - would fail alone) AND motion — motion must run.
# Idle MENU fails; motion runs; aggregate keeps failure but motion_hook line must appear.
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PAIR_IDLE_PNG="$FIX/postboot_menu.png" \
  PROMOTE_MOTION_CMD="$WORK/motion0.sh" \
  env -u PROMOTE_VISUAL_CMD \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [both] /' | tail -25
echo "  [both] true rc=$rc"
echo "$out" | grep -q 'motion_hook true rc=0' && ok "motion-ran-with-idle" || bad "motion-ran-with-idle"
echo "$out" | grep -q 'visual_idle true rc=' && ok "idle-also-ran" || bad "idle-also-ran"
# MENU idle must fail overall
[ "$rc" -ne 0 ] && ok "menu-idle-keeps-red" || bad "menu-idle-keeps-red"

echo "=== motion alone still reaches green path ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_MOTION_CMD="$WORK/motion0.sh" \
  env -u PROMOTE_VISUAL_CMD -u PAIR_IDLE_PNG -u PAIR_CAPTURE_CMD \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [mot] /' | tail -15
echo "  [mot] true rc=$rc"
[ "$rc" -eq 0 ] && ok "motion-alone-green" || bad "motion-alone-green rc=$rc"
echo "$out" | grep -q 'PROMOTE_GATES_OK' && ok "motion-alone-ok-marker" || bad "motion-alone-ok-marker"
echo "$out" | grep -q 'motion_hook true rc=0' && ok "motion-alone-ran" || bad "motion-alone-ran"

echo "=== promotion gate RED on decoy-good LIVE-bad hook inject ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_HOOK_BLOB="$BOOT/user-startup.sh.LIVE" \
  PROMOTE_HOOK_DECOY_BLOB="$BOOT/_user-startup.sh.DECOY" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [gate-decoy] /' | tail -20
echo "  [gate-decoy] true rc=$rc"
[ "$rc" -ne 0 ] && ok "gate-decoy-red" || bad "gate-decoy-red"
echo "$out" | grep -qiE 'decoy|boot-hook|BOOT_HOOK_FAIL' && ok "gate-decoy-msg" || bad "gate-decoy-msg"

echo "=== live_object.inc refuse helpers ==="
set +e
out=$(live_object_refuse_disk_only "core-md5" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "refuse-disk" || bad "refuse-disk"
set +e
out=$(live_object_assert_http_code 200 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "http-200" || bad "http-200"
set +e
out=$(live_object_assert_http_code 503 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "http-503" || bad "http-503"

echo "=== summary pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "test_live_object_integrity: FAIL"
  echo "true rc=1"
  exit 1
fi
echo "test_live_object_integrity: OK"
echo "true rc=0"
exit 0
