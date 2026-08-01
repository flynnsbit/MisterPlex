#!/usr/bin/env bash
# Host-only: measured-md5 bak naming + mislabel fail-closed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/daemon_backup_policy.sh"
WORK="$ROOT/build/test-daemon-backup-policy"
rm -rf "$WORK"
mkdir -p "$WORK/bin"
pass=0; fail=0
ok(){ echo "PASS $1"; pass=$((pass+1)); }
bad(){ echo "FAIL $1" >&2; fail=$((fail+1)); }

printf 'daemon-bytes-A\n' >"$WORK/bin/payload"
md=$(md5sum "$WORK/bin/payload" | awk '{print $1}')
p8=${md:0:8}

echo "=== name-for ==="
out=$("$ROOT/scripts/daemon_backup_policy.sh" name-for "$md")
echo "$out" | grep -q "CANONICAL=misterplexd.${p8}.bak" && ok "name-canonical" || bad "name-canonical"
echo "$out" | grep -q "ALIAS=misterplexd.bak.${p8}" && ok "name-alias" || bad "name-alias"
echo "$out" | grep -q "STAGE=misterplexd.stage.${p8}" && ok "name-stage" || bad "name-stage"

echo "=== GREEN verified pin ==="
cp -p "$WORK/bin/payload" "$WORK/bin/misterplexd.${p8}.bak"
set +e
daemon_bak_verify_name "$WORK/bin/misterplexd.${p8}.bak" >"$WORK/v.out" 2>&1
rc=$?
set -e
echo "  [verify-ok] true rc=$rc"
[ "$rc" -eq 0 ] && ok "verify-ok" || bad "verify-ok"
cp -p "$WORK/bin/payload" "$WORK/bin/misterplexd.bak.${p8}"
daemon_bak_verify_name "$WORK/bin/misterplexd.bak.${p8}" >/dev/null && ok "verify-alias" || bad "verify-alias"

echo "=== RED mislabel (name claims other md5) ==="
cp -p "$WORK/bin/payload" "$WORK/bin/misterplexd.bak.deadbeef"
set +e
daemon_bak_verify_name "$WORK/bin/misterplexd.bak.deadbeef" >"$WORK/mis.out" 2>&1
rc=$?
set -e
echo "  [mislabel] true rc=$rc"
[ "$rc" -eq 1 ] && ok "mislabel-rc1" || bad "mislabel-rc1"
grep -q MISLABEL "$WORK/mis.out" && ok "mislabel-msg" || bad "mislabel-msg"

echo "=== RED legacy unverified ==="
cp -p "$WORK/bin/payload" "$WORK/bin/misterplexd.bak.osd"
set +e
daemon_bak_verify_name "$WORK/bin/misterplexd.bak.osd" >"$WORK/leg.out" 2>&1
rc=$?
set -e
echo "  [legacy] true rc=$rc"
[ "$rc" -eq 3 ] && ok "legacy-rc3" || bad "legacy-rc3"

echo "=== path helpers ==="
c=$(daemon_bak_canonical_path "$WORK/bin" "$md")
[ "$c" = "$WORK/bin/misterplexd.${p8}.bak" ] && ok "canon-path" || bad "canon-path"
a=$(daemon_bak_alias_path "$WORK/bin" "$md")
[ "$a" = "$WORK/bin/misterplexd.bak.${p8}" ] && ok "alias-path" || bad "alias-path"
s=$(daemon_bak_stage_path "$WORK/bin" "$md")
[ "$s" = "$WORK/bin/misterplexd.stage.${p8}" ] && ok "stage-path" || bad "stage-path"

"$ROOT/scripts/daemon_backup_policy.sh" retention-policy | grep -q 'never rm' && ok "retention-doc" || bad "retention-doc"
out_inv=$("$ROOT/scripts/daemon_backup_policy.sh" inventory-plan)
echo "$out_inv" | grep -q 'VERIFIED_PIN' && ok "inventory-plan" || bad "inventory-plan"
echo "$out_inv" | grep -q 'never rm' && ok "inventory-retention" || bad "inventory-retention"

echo "=== summary pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ]
echo "true rc=$?"
