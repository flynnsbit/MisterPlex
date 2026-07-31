#!/usr/bin/env bash
# Host-only: boot hook policy red-before-green (cold-boot defect class).
# Never touches the device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=boot_hook_policy.sh
source "$ROOT/scripts/boot_hook_policy.sh"
WORK="$ROOT/build/boot-hook-test"
rm -rf "$WORK"
mkdir -p "$WORK"
bash -n "$ROOT/scripts/boot_hook_policy.sh"
bash -n "$ROOT/scripts/misterplexd_supervise.sh"
chmod +x "$ROOT/scripts/misterplexd_supervise.sh" "$ROOT/scripts/boot_hook_policy.sh"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

V1=/media/fat/misterplex
V2=/media/fat/misterplex_v2

echo "=== RED: v1-only hook (the measured cold-boot defect) ==="
v1_hook="# other stuff
nohup ${V1}/bin/misterplexd_supervise.sh >>${V1}/misterplexd_supervise.log 2>&1 &
"
set +e
out=$(boot_hook_check_body "$v1_hook" "$V2" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
[ "$rc" -eq 1 ] && ok "v1-hook-vs-v2-expect" || bad "v1-hook-vs-v2-expect rc=$rc"
echo "$out" | grep -qi 'mismatch\|v1_hook\|expect' && ok "v1-msg" || bad "v1-msg"

echo "=== RED: v1+v2 double line (idempotence trap) ==="
dbl="# keep
nohup ${V1}/bin/misterplexd_supervise.sh >>${V1}/misterplexd_supervise.log 2>&1 &
nohup ${V2}/bin/misterplexd_supervise.sh >>${V2}/misterplexd_supervise.log 2>&1 &
"
set +e
out=$(boot_hook_check_body "$dbl" "$V2" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 1 ] && ok "double-line" || bad "double-line rc=$rc"
echo "$out" | grep -qi 'multiple' && ok "double-msg" || bad "double-msg"

echo "=== RED: bare misterplexd autostart (legacy package_release) ==="
bare="nohup ${V2}/bin/misterplexd --name X --conf ${V2}/misterplex.conf >>log 2>&1 &"
set +e
out=$(boot_hook_check_body "$bare" "$V2" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] && ok "bare-daemon" || bad "bare-daemon rc=$rc"

echo "=== RED: empty hook ==="
set +e
out=$(boot_hook_check_body "# nothing" "$V2" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] && ok "empty-hook" || bad "empty-hook rc=$rc"

echo "=== GREEN: exact v2 supervise line ==="
good=$(boot_hook_line_for_root "$V2")
set +e
out=$(boot_hook_check_body "$good" "$V2" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "v2-ok" || bad "v2-ok rc=$rc"

echo "=== render strips v1 and installs exactly one v2 line ==="
old="# wifi
some other line
nohup ${V1}/bin/misterplexd_supervise.sh >>${V1}/misterplexd_supervise.log 2>&1 &
# MiSTerPlex companion
nohup ${V2}/bin/misterplexd --name X --conf c >>l 2>&1 &
"
rendered=$(boot_hook_render_body "$V2" "$old")
printf '%s\n' "$rendered" >"$WORK/rendered.hook"
echo "$rendered" | sed 's/^/  /'
set +e
out=$(boot_hook_check_body "$rendered" "$V2" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "render-check" || bad "render-check rc=$rc out=$out"
echo "$rendered" | grep -q "${V1}/bin" && bad "render-left-v1" || ok "render-no-v1"
n=$(echo "$rendered" | grep -c misterplexd_supervise.sh || true)
[ "$n" -eq 1 ] && ok "render-one-line" || bad "render-one-line n=$n"
echo "$rendered" | grep -q 'some other line' && ok "render-kept-other" || bad "render-kept-other"

echo "=== CLI check red/green ==="
set +e
"$ROOT/scripts/boot_hook_policy.sh" check "$WORK/rendered.hook" "$V2" >/dev/null
rc=$?
set -e
echo "  cli-green true rc=$rc"
[ "$rc" -eq 0 ] && ok "cli-green" || bad "cli-green"
printf '%s\n' "$v1_hook" >"$WORK/v1.hook"
set +e
"$ROOT/scripts/boot_hook_policy.sh" check "$WORK/v1.hook" "$V2" >/dev/null
rc=$?
set -e
echo "  cli-red true rc=$rc"
[ "$rc" -eq 1 ] && ok "cli-red" || bad "cli-red"

echo "=== supervisor source has flock + HEALTHY_SECS + exact MiSTer argv0 ==="
src=$(cat "$ROOT/scripts/misterplexd_supervise.sh")
echo "$src" | grep -q 'flock -n' && ok "sup-flock" || bad "sup-flock"
echo "$src" | grep -q 'HEALTHY_SECS' && ok "sup-healthy" || bad "sup-healthy"
echo "$src" | grep -q '/media/fat/MiSTer' && ok "sup-mister-argv0" || bad "sup-mister-argv0"
echo "$src" | grep -q 'misterplex.conf' && ok "sup-conf" || bad "sup-conf"

echo "=== P0: parse USER_SCRIPT from S99user (real path, not decoy) ==="
cat >"$WORK/s99.real" <<'S99'
#!/bin/sh
# MiSTer user script launcher
USER_SCRIPT="/media/fat/linux/user-startup.sh"
S99
set +e
path=$(boot_hook_parse_user_script "$(cat "$WORK/s99.real")")
rc=$?
set -e
echo "  USER_SCRIPT=$path true rc=$rc"
[ "$rc" -eq 0 ] && ok "parse-s99-rc0" || bad "parse-s99-rc0"
[ "$path" = "/media/fat/linux/user-startup.sh" ] && ok "parse-s99-path" || bad "parse-s99-path got=$path"
[ "$path" != "/media/fat/linux/_user-startup.sh" ] && ok "parse-not-decoy" || bad "parse-not-decoy"

echo "=== P0: missing/unparseable S99 is hard FAIL (no guess) ==="
set +e
boot_hook_parse_user_script "MISSING" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "s99-missing-fail" || bad "s99-missing-fail"
set +e
boot_hook_parse_user_script "# no assignment here" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "s99-unparseable-fail" || bad "s99-unparseable-fail"

echo "=== P0: decoy with v1 supervise is FAIL (inert policy) ==="
decoy_v1="nohup ${V1}/bin/misterplexd_supervise.sh >>${V1}/misterplexd_supervise.log 2>&1 &
"
set +e
out=$(boot_hook_check_decoy_body "$decoy_v1" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  decoy-v1 true rc=$rc"
[ "$rc" -ne 0 ] && ok "decoy-armed-fail" || bad "decoy-armed-fail"
echo "$out" | grep -qi 'decoy_has_misterplex' && ok "decoy-armed-msg" || bad "decoy-armed-msg"

echo "=== P0: inert decoy OK ==="
set +e
out=$(boot_hook_check_decoy_body "# wifi only" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "decoy-inert-ok" || bad "decoy-inert-ok"
set +e
out=$(boot_hook_check_decoy_body "ABSENT" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "decoy-absent-ok" || bad "decoy-absent-ok"

echo "=== P0: render_inert_decoy strips misterplex ==="
rendered_d=$(boot_hook_render_inert_decoy "$decoy_v1"$'\n'"other=1")
echo "$rendered_d" | grep -q misterplexd && bad "render-decoy-left-mp" || ok "render-decoy-stripped"
echo "$rendered_d" | grep -q 'DECOY' && ok "render-decoy-marker" || bad "render-decoy-marker"

echo "=== promotion gate fails on v1 REAL hook (with S99 derivation) ==="
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
printf '%s\n' "$v1_hook" >"$WORK/bad.hook"
printf '%s\n' "# inert" >"$WORK/inert.decoy"
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
cat >"$WORK/conf_ddr.txt" <<'C'
DDR_YUV_FORCE_SCALE=1
FFMPEG_SWS_FLAGS=fast_bilinear
C
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/bad.hook" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/inert.decoy" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$ROOT/scripts/promotion_gate_check.sh" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [gate] /' | tail -20
echo "  [gate] true rc=$rc"
[ "$rc" -ne 0 ] && ok "gate-v1-hook-fail" || bad "gate-v1-hook-fail should not pass"
echo "$out" | grep -qi 'boot-hook' && ok "gate-boot-msg" || bad "gate-boot-msg"
echo "$out" | grep -q 'USER_SCRIPT=/media/fat/linux/user-startup.sh' && ok "gate-derived-path" || bad "gate-derived-path"

echo "=== P0 REGRESSION: good REAL v2 hook but ARMED decoy → FAIL (was blind-green) ==="
printf '%s\n' "$good" >"$WORK/good.hook"
printf '%s\n' "$decoy_v1" >"$WORK/armed.decoy"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/armed.decoy" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$ROOT/scripts/promotion_gate_check.sh" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [armed-decoy] /' | tail -15
echo "  [armed-decoy] true rc=$rc"
[ "$rc" -ne 0 ] && ok "gate-armed-decoy-fail" || bad "gate-armed-decoy-fail"
echo "$out" | grep -qi 'decoy' && ok "gate-armed-decoy-msg" || bad "gate-armed-decoy-msg"
# Must NOT claim PROMOTE_GATES_OK
echo "$out" | grep -q 'PROMOTE_GATES_OK' && bad "gate-armed-decoy-false-ok" || ok "gate-armed-decoy-no-ok"

echo "=== promotion gate GREEN: S99-derived path + v2 REAL hook + inert decoy ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/inert.decoy" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$ROOT/scripts/promotion_gate_check.sh" verify-live 2>&1
)
rc=$?
set -e
echo "  [gate-ok] true rc=$rc"
echo "$out" | sed 's/^/  [gate-ok] /' | tail -16
[ "$rc" -eq 0 ] && ok "gate-v2-hook-ok" || bad "gate-v2-hook-ok rc=$rc"
echo "$out" | grep -q 'boot-hook-path-from-init' && ok "gate-ok-from-init" || bad "gate-ok-from-init"
echo "$out" | grep -q 'OK boot-hook decoy inert' && ok "gate-ok-decoy-inert" || bad "gate-ok-decoy-inert"
echo "$out" | grep -q 'user-startup.sh' && ok "gate-ok-real-name" || bad "gate-ok-real-name"
# Must not only mention underscore decoy as the checked path without real
echo "$out" | grep -q 'boot-hook-real-path=/media/fat/linux/user-startup.sh' && ok "gate-ok-real-path-line" || bad "gate-ok-real-path-line"

echo "=== REGRESSION: gate source must not hardcode decoy as sole boot path ==="
set +e
out=$(boot_hook_audit_source_hardcodes "$ROOT" 2>&1)
rc=$?
set -e
echo "$out" | sed 's/^/  [audit] /'
echo "  audit true rc=$rc"
[ "$rc" -eq 0 ] && ok "source-audit-ok" || bad "source-audit-ok"
# Explicit: promotion_gate_check live fetch must reference S99user
grep -q 'S99user' "$ROOT/scripts/promotion_gate_check.sh" && ok "gate-refs-s99" || bad "gate-refs-s99"
grep -q 'boot_hook_parse_user_script' "$ROOT/scripts/promotion_gate_check.sh" && ok "gate-uses-parse" || bad "gate-uses-parse"
# rollback resolve
grep -q 'resolve_boot_hook_path' "$ROOT/scripts/rollback_v2.sh" && ok "rollback-resolve" || bad "rollback-resolve"
grep -q 'S99user' "$ROOT/scripts/deploy_misterplexd.sh" && ok "deploy-s99" || bad "deploy-s99"

echo "=== summary pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ] || exit 1
echo "ALL test_boot_hook_policy checks passed"
echo "true rc=0"
exit 0
