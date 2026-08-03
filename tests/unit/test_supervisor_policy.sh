#!/usr/bin/env bash
# Red-before-green: supervisor SoT policy + md5 shape + dual-root boot strip.
#
# Parent 2026-08-02: device supervisor md5 59286a1d in NO commit; deploy must
# ship repo SoT and refuse drift. V2_MD5 `…81848set +e` must fail shape, not
# fuzzy-trim. Boot rewrite must strip v1 AND v2 so two daemons cannot start.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/supervisor_policy.sh
source "$ROOT/scripts/supervisor_policy.sh"
# shellcheck source=../../scripts/boot_hook_policy.sh
source "$ROOT/scripts/boot_hook_policy.sh"

fails=0
applied=0
ok() { echo "OK $*"; applied=$((applied + 1)); }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

WORK="$ROOT/build/test_supervisor_policy_$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO_SUP="$(supervisor_repo_path "$ROOT")"
REPO_MD5="$(supervisor_repo_md5 "$REPO_SUP")"

echo "=== GREEN: repo supervisor capabilities + md5 shape ==="
set +e
supervisor_assert_capabilities "$REPO_SUP"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then ok "repo-caps rc=0"; else bad "repo-caps rc=$rc"; fi
set +e
supervisor_assert_md5_shape "repo" "$REPO_MD5"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then ok "repo-md5-shape"; else bad "repo-md5-shape rc=$rc"; fi
set +e
supervisor_assert_md5_match "repo-self" "$REPO_MD5" "$REPO_MD5"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then ok "repo-md5-self-match"; else bad "repo-md5-self-match rc=$rc"; fi

echo "=== RED: md5 mismatch (device drift class) ==="
set +e
supervisor_assert_md5_match "drift" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$REPO_MD5"
rc=$?
set -e
if [ "$rc" -eq 1 ]; then ok "drift-mismatch-rc=1"; else bad "drift-mismatch want rc=1 got=$rc"; fi
grep -q 'md5_mismatch' <<<"$(supervisor_assert_md5_match "drift2" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$REPO_MD5" 2>&1 || true)" \
  && ok "drift-msg" || bad "drift-msg"

echo "=== RED: V2_MD5 malformed_capture (…81848set +e) — never fuzzy-trim ==="
CONTAM="dfebf2bfd08dd70b473b587dd7e81848set +e"
set +e
out=$(supervisor_assert_md5_shape "v2md5" "$CONTAM" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 3 ]; then ok "malformed-shape-rc=3"; else bad "malformed-shape want rc=3 got=$rc out=$out"; fi
printf '%s\n' "$out" | grep -q 'malformed_capture' && ok "malformed-token" || bad "malformed-token"
printf '%s\n' "$out" | grep -q 'never_fuzzy_trim' && ok "malformed-no-trim" || bad "malformed-no-trim"
# Equality path must also refuse (not strip to 32 hex and pass).
set +e
out2=$(supervisor_assert_md5_match "v2eq" "$CONTAM" "dfebf2bfd08dd70b473b587dd7e81848" 2>&1)
rc2=$?
set -e
if [ "$rc2" -eq 3 ]; then ok "malformed-match-rc=3"; else bad "malformed-match want rc=3 got=$rc2"; fi

echo "=== RED: empty got is NO-DATA rc=4 ==="
set +e
supervisor_assert_md5_shape "empty" ""
rc=$?
set -e
if [ "$rc" -eq 4 ]; then ok "empty-nodata-rc=4"; else bad "empty-nodata want rc=4 got=$rc"; fi

echo "=== RED: supervisor missing HEALTHY_SECS / exact argv0 ==="
cat >"$WORK/bad_sup.sh" <<'EOF'
#!/bin/sh
# intentionally broken — no HEALTHY_SECS, substring Main match
while true; do
  for d in /proc/[0-9]*; do
    a0=$(tr '\0' '\n' <"$d/cmdline" | head -1)
    case "$a0" in *MiSTer*) kill -CONT "${d#/proc/}";; esac
  done
  sleep 1
done
EOF
set +e
supervisor_assert_capabilities "$WORK/bad_sup.sh"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then ok "bad-caps-rc=$rc"; else bad "bad-caps should fail"; fi

echo "=== GREEN: boot strip removes v1+v2 dual lines → single expect root ==="
DUAL=$(cat <<'EOF'
# leftover noise
nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
nohup /media/fat/misterplex_v2/bin/misterplexd --name x &
nohup /tmp/plexctl_supervise.sh &
keep_me_other_service
EOF
)
set +e
boot_hook_check_body "$DUAL" "/media/fat/misterplex_v2"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then ok "dual-body-fails-check rc=$rc"; else bad "dual-body should fail check"; fi

RENDERED=$(boot_hook_render_body "/media/fat/misterplex_v2" "$DUAL")
set +e
boot_hook_check_body "$RENDERED" "/media/fat/misterplex_v2"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then ok "render-single-v2"; else bad "render-single-v2 rc=$rc body=$RENDERED"; fi
printf '%s\n' "$RENDERED" | grep -q 'misterplex_v2/bin/misterplexd_supervise.sh' && ok "render-has-v2" || bad "render-has-v2"
printf '%s\n' "$RENDERED" | grep -qE '/misterplex/bin/misterplexd' && bad "render-still-v1" || ok "render-no-v1"
printf '%s\n' "$RENDERED" | grep -q 'plexctl_supervise' && bad "render-still-plexctl" || ok "render-no-plexctl"
printf '%s\n' "$RENDERED" | grep -q 'keep_me_other_service' && ok "render-keeps-other" || bad "render-keeps-other"

n=$(printf '%s\n' "$RENDERED" | grep -c 'misterplexd_supervise.sh' || true)
if [ "$n" -eq 1 ]; then ok "render-n-sup=1"; else bad "render-n-sup=$n"; fi

echo "=== STRUCTURAL: deploy ships supervisor_policy + SUP_MD5_MATCH_OK ==="
DEP="$ROOT/scripts/deploy_misterplexd.sh"
grep -q 'supervisor_policy.sh' "$DEP" && ok "deploy-deps-policy" || bad "deploy-deps-policy"
grep -q 'SUP_MD5_MATCH_OK' "$DEP" && ok "deploy-sup-md5-gate" || bad "deploy-sup-md5-gate"
grep -q 'supervisor_boot_strip_eregex\|strip_re=' "$DEP" && ok "deploy-strip-re" || bad "deploy-strip-re"
grep -q 'supervisor_assert_capabilities' "$DEP" && ok "deploy-caps-gate" || bad "deploy-caps-gate"

echo "=== STRUCTURAL: plexctl uses durable SoT (no embedded heredoc supervisor) ==="
PLEX="$ROOT/scripts/plexctl.sh"
grep -q 'require_durable_supervisor' "$PLEX" && ok "plexctl-durable" || bad "plexctl-durable"
if grep -q 'cat > /tmp/plexctl_supervise.sh <<' "$PLEX"; then
  bad "plexctl-still-embeds-supervisor"
else
  ok "plexctl-no-embed"
fi

echo "=== STRUCTURAL: rollback classify_hash refuses set +e glue ==="
# Source just the function via bash -c extract is heavy; grep the source contract.
grep -q 'malformed_capture' "$ROOT/scripts/rollback_v2.sh" && ok "rollback-malformed-token" || bad "rollback-malformed-token"
grep -q 'never_fuzzy_trim_set_+e_glue' "$ROOT/scripts/rollback_v2.sh" && ok "rollback-no-trim" || bad "rollback-no-trim"

# applied-match count: mutation that deletes asserts cannot claim green.
want=26
if [ "$applied" -eq "$want" ] && [ "$fails" -eq 0 ]; then
  echo "SUPERVISOR_POLICY applied_match=$applied want=$want"
  echo "test_supervisor_policy: OK"
  exit 0
fi
echo "SUPERVISOR_POLICY applied_match=$applied want=$want fails=$fails"
echo "test_supervisor_policy: FAIL"
exit 1
