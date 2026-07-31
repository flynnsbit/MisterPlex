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

echo "=== promotion gate fails on v1 hook blob ==="
# minimal live blob + bad hook
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
  PROMOTE_HOOK_BLOB="$WORK/bad.hook" \
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

echo "=== promotion gate GREEN with matching v2 hook ==="
printf '%s\n' "$good" >"$WORK/good.hook"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live.blob" \
  PROMOTE_HTTP="$WORK/http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis.sh" \
  PROMOTE_HOOK_BLOB="$WORK/good.hook" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$ROOT/scripts/promotion_gate_check.sh" verify-live 2>&1
)
rc=$?
set -e
echo "  [gate-ok] true rc=$rc"
echo "$out" | sed 's/^/  [gate-ok] /' | tail -12
[ "$rc" -eq 0 ] && ok "gate-v2-hook-ok" || bad "gate-v2-hook-ok rc=$rc"

echo "=== summary pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ] || exit 1
echo "ALL test_boot_hook_policy checks passed"
exit 0
