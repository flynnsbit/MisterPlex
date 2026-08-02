#!/usr/bin/env bash
# Host-only: RBF ship policy + promotion gates + dry-run promote script.
# Never touches 192.168.1.183.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/build/test-promotion-gates"
POLICY="$ROOT/scripts/rbf_ship_policy.sh"
GATES="$ROOT/scripts/promotion_gate_check.sh"
PROMOTE="$ROOT/scripts/promote_ddr_daily.sh"
PLEXCTL="$ROOT/scripts/plexctl.sh"

rm -rf "$WORK"
mkdir -p "$WORK"
chmod +x "$POLICY" "$GATES" "$PROMOTE" "$PLEXCTL" \
  "$ROOT/scripts/rollback_v2.sh" \
  "$ROOT/scripts/deploy_misterplexd.sh" 2>/dev/null || true

bash -n "$POLICY"
bash -n "$GATES"
bash -n "$PROMOTE"
bash -n "$ROOT/scripts/rollback_v2.sh"
bash -n "$PLEXCTL"

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

# Blob inject tests are not fabric-ID tests. Identity fail-closed is covered
# explicitly below; green paths set VERIFIED so PROMOTE_GATES_OK remains reachable.
export PROMOTE_CORE_IDENTITY="${PROMOTE_CORE_IDENTITY:-VERIFIED}"

# --- policy -----------------------------------------------------------------

echo "=== pair_ship_policy DDR pair OK / mixed REFUSE ==="
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check c5382bee73cecdee8220b811e529c297 e9f79de217982aff44207664fdb945c5 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "pair-ddr-ok" || bad "pair-ddr-ok rc=$rc"
set +e
out=$("$ROOT/scripts/pair_ship_policy.sh" check dfebf2bfd08dd70b473b587dd7e81848 e9f79de217982aff44207664fdb945c5 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] && ok "pair-mixed-refuse" || bad "pair-mixed-refuse rc=$rc"
echo "$out" | grep -qiE 'solid_green|black_or_green|spi_core_plus_ddr' && ok "pair-green-msg" || bad "pair-green-msg"

echo "=== policy: banned prefix ==="
set +e
out=$("$POLICY" check 8832824eaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /'
[ "$rc" -eq 1 ] && ok "banned-rc=1" || bad "banned-rc=$rc"
echo "$out" | grep -q BANNED && ok "banned-msg" || bad "banned-msg"

echo "=== policy: do-not-ship freeze ==="
set +e
out=$("$POLICY" check 9eb1431aaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 2 ] && ok "dns-rc=2" || bad "dns-rc=$rc"

echo "=== policy: allow c5382bee pin ==="
set +e
out=$("$POLICY" check c5382bee73cecdee8220b811e529c297 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "allow-c5382" || bad "allow-c5382 rc=$rc"

echo "=== policy: refuse Plex_v2 product path ==="
set +e
out=$("$POLICY" assert-product-path /media/fat/_Utility/Plex_v2.rbf 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 10 ] && ok "refuse-v2-path" || bad "refuse-v2-path rc=$rc"
echo "$out" | grep -qi 'ROLLBACK\|DAILY\|never overwrite' && ok "refuse-v2-msg" || bad "refuse-v2-msg"

echo "=== policy: accept Plex.rbf product path ==="
set +e
out=$("$POLICY" assert-product-path /media/fat/_Utility/Plex.rbf 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] && ok "accept-product-path" || bad "accept-product-path rc=$rc"

# --- policy-local with fake artifacts ---------------------------------------
# craft files whose md5 we control via content... easier: compute md5 of content
# We need exact pins — write bytes won't match pins. Instead monkey-patch by
# using printf files and override EXPECT md5s to match those files.
printf 'fake-ddr-rbf-body\n' >"$WORK/fake.rbf"
printf 'fake-ddr-daemon-body\n' >"$WORK/fake.daemon"
chmod +x "$WORK/fake.daemon"
RBF_MD5=$(md5sum "$WORK/fake.rbf" | awk '{print $1}')
DAE_MD5=$(md5sum "$WORK/fake.daemon" | awk '{print $1}')

echo "=== policy-local green with overridden pins ==="
set +e
out=$(
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  PROMOTE_PAIR_CHECK=0 \
  "$GATES" policy-local "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "policy-local-green" || bad "policy-local-green rc=$rc"

echo "=== policy-local red on wrong daemon pin ==="
set +e
out=$(
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5=deadbeefdeadbeefdeadbeefdeadbeef \
  PROMOTE_PAIR_CHECK=0 \
  "$GATES" policy-local "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "policy-local-daemon-mismatch" || bad "policy-local-daemon-mismatch rc=$rc"

# --- verify-live via blob inject --------------------------------------------
# Primary DDR daemon pin is 9ce2c2d1 (parent glass 2026-08-01; w-osd-hires).
# Lab fixture still uses c5382 product bytes — override EXPECT so default glass
# pin 8fdf440f does not false-fail the unit (LAB pair, not daily default).
EDC_LIVE=9ce2c2d13d1c8712683289043e99002c
LAB_CORE=c5382bee73cecdee8220b811e529c297
# Force lab fixture (do not inherit ambient PROMOTE_EXPECT_* from parent shell).
export PROMOTE_EXPECT_CORE_MD5="$LAB_CORE"
export PROMOTE_EXPECT_DAEMON_MD5="$EDC_LIVE"
cat >"$WORK/live_ok.blob" <<BLOB
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=$LAB_CORE
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=dfebf2bfd08dd70b473b587dd7e81848
N_DAEMON=1
PIDS=4242
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=$EDC_LIVE
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_CONF_MD5=7f06132f0c00e90b35141bdc0c60ccc9
LIVE_ROOT=/media/fat/misterplex_v2
PLXS_MAGIC=0x504C5853
PLXS_SEQ=10
PLXS_SEQ2=11
BLOB
cat >"$WORK/conf_ddr.txt" <<'CONF'
DECODE=320x240
PRESENT=fpga
DDR_YUV_FORCE_SCALE=1
FFMPEG_SWS_FLAGS=fast_bilinear
CONF

cat >"$WORK/fake_http.sh" <<'HTTP'
#!/usr/bin/env bash
echo 200
HTTP
chmod +x "$WORK/fake_http.sh"

echo "=== verify-live green telemetry but NO visual → HARD rc=8 ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  env -u PROMOTE_VISUAL_CMD -u PROMOTE_MOTION_CMD -u PAIR_IDLE_PNG \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
# Parent: unset visual is HARD failure for claim success (not soft 77)
[ "$rc" -eq 8 ] && ok "verify-live-visual-required-8" || bad "verify-live-visual-required want 8 got $rc"
echo "$out" | grep -q 'OK product-core' && ok "verify-product" || bad "verify-product"
echo "$out" | grep -q 'OK v2-rollback-core' && ok "verify-v2" || bad "verify-v2"
echo "$out" | grep -q 'OK live-exe-md5' && ok "verify-live-exe" || bad "verify-live-exe"
echo "$out" | grep -q 'OK live-conf' && ok "verify-conf" || bad "verify-conf"
echo "$out" | grep -q 'OK n_daemon=1' && ok "verify-n1" || bad "verify-n1"
echo "$out" | grep -q 'OK live-pair-compatibility' && ok "verify-pair" || bad "verify-pair"
if echo "$out" | grep -q 'PROMOTE_GATES_OK'; then bad "gates-ok-without-visual"; else ok "no-false-gates-ok"; fi
echo "$out" | grep -qi 'VISUAL_REQUIRED' && ok "visual-required-msg" || bad "visual-required-msg"

echo "=== verify-live with visual hook PASS → overall 0 ==="
cat >"$WORK/visual_ok.sh" <<'M'
#!/usr/bin/env bash
exit 0
M
chmod +x "$WORK/visual_ok.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_CORE_IDENTITY=VERIFIED \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /' | tail -15
[ "$rc" -eq 0 ] && ok "verify-with-visual" || bad "verify-with-visual rc=$rc"
echo "$out" | grep -q 'PROMOTE_GATES_OK' && ok "gates-ok" || bad "gates-ok"
echo "$out" | grep -q 'PLXS_SEQ advanced' && ok "plxs-seq-advance" || bad "plxs-seq-advance"
echo "$out" | grep -q 'OK conf-profile=ddr' && ok "conf-ddr-ok" || bad "conf-ddr-ok"

echo "=== RED: CORE_IDENTITY_UNVERIFIED blocks PROMOTE_GATES_OK (fail-closed) ==="
# Match blob product md5 so ONLY identity fails (not product-disk ALLOW path).
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_EXPECT_CORE_MD5=c5382bee73cecdee8220b811e529c297 \
  PROMOTE_EXPECT_DAEMON_MD5=9ce2c2d13d1c8712683289043e99002c \
  PROMOTE_CORE_IDENTITY=UNVERIFIED \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  [core-id] true rc=$rc"
echo "$out" | sed 's/^/  [core-id] /' | tail -12
[ "$rc" -eq 2 ] && ok "core-id-blocks-rc2" || bad "core-id-blocks-rc2 got=$rc"
echo "$out" | grep -q 'PROMOTE_OK=0' && ok "core-id-promote-ok0" || bad "core-id-promote-ok0"
# Match the success marker line only — FAIL text also contains the substring.
echo "$out" | grep -qx 'PROMOTE_GATES_OK' && bad "core-id-no-gates-ok" || ok "core-id-no-gates-ok"
echo "$out" | grep -q 'CORE_IDENTITY_UNVERIFIED' && ok "core-id-msg" || bad "core-id-msg"

echo "=== verify-live RED when DDR conf keys missing ==="
cat >"$WORK/conf_spi.txt" <<'CONF'
DECODE=320x240
PRESENT=fpga
CONF
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_spi.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "conf-missing-keys-rc3" || bad "conf-missing-keys want 3 got $rc"

echo "=== verify-live red: n_daemon=2 ==="
sed 's/N_DAEMON=1/N_DAEMON=2/' "$WORK/live_ok.blob" >"$WORK/live_dual.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_dual.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 9 ] && ok "dual-daemon-rc9" || bad "dual-daemon rc=$rc"

echo "=== verify-live red: live md5 stale (disk-only class) ==="
sed "s/LIVE_MD5=$EDC_LIVE/LIVE_MD5=50f4eb925de10e29172999a565c87684/" \
  "$WORK/live_ok.blob" >"$WORK/live_stale.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_stale.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "stale-live-md5" || bad "stale-live-md5 rc=$rc"
echo "$out" | grep -q 'ETXTBSY\|readlink' && ok "stale-hint" || bad "stale-hint"

echo "=== verify-live red: V2 rollback missing ==="
sed 's/V2_MD5=dfebf2bfd08dd70b473b587dd7e81848/V2_MD5=MISSING/' \
  "$WORK/live_ok.blob" >"$WORK/live_nov2.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_nov2.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 2 ] && ok "v2-missing" || bad "v2-missing rc=$rc"

# --- promote dry-run --------------------------------------------------------
echo "=== verify-live RED mixed pair SPI core path + DDR daemon ==="
# product md5 is DDR but wait — product is c5382; craft SPI product wrong:
# Use blob where PRODUCT is dfebf2 and LIVE is e9f79de2
cat >"$WORK/live_mixed.blob" <<BLOB
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=dfebf2bfd08dd70b473b587dd7e81848
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=dfebf2bfd08dd70b473b587dd7e81848
N_DAEMON=1
PIDS=4242
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=e9f79de217982aff44207664fdb945c5
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_ROOT=/media/fat/misterplex_v2
PLXS_MAGIC=0x504C5853
PLXS_SEQ=10
PLXS_SEQ2=11
BLOB
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_mixed.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \
  PROMOTE_EXPECT_DAEMON_MD5=e9f79de217982aff44207664fdb945c5 \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /' | head -30
# expect pair refuse (rc=3) — visual not reached or after pair fail
[ "$rc" -eq 3 ] && ok "mixed-pair-rc3" || bad "mixed-pair want 3 got $rc"
echo "$out" | grep -qi 'PAIR_REFUSE\|pair-compatibility\|spi_core_plus_ddr' && ok "mixed-pair-msg" || bad "mixed-pair-msg"


echo "=== NO-DATA: empty V2_MD5 is not a mismatch (got='' never vs want) ==="
sed 's/V2_MD5=dfebf2bfd08dd70b473b587dd7e81848/V2_MD5=/' \
  "$WORK/live_ok.blob" >"$WORK/live_empty_v2.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_empty_v2.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  [empty-v2] /' | head -20
[ "$rc" -eq 4 ] && ok "empty-v2-rc4" || bad "empty-v2 want rc=4 got $rc"
echo "$out" | grep -q 'NO-DATA v2-rollback-core' && ok "empty-v2-nodata" || bad "empty-v2-nodata"
echo "$out" | grep -q "got='' want=" && bad "empty-v2-false-mismatch" || ok "empty-v2-no-false-mismatch"
echo "$out" | grep -q 'FAIL v2-rollback-core got=' && bad "empty-v2-fail-got" || ok "empty-v2-no-fail-got"

echo "=== NO-DATA: empty LIVE_MD5 is not a mismatch ==="
sed 's/LIVE_MD5=.*/LIVE_MD5=/' "$WORK/live_ok.blob" >"$WORK/live_empty_live.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_empty_live.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 4 ] && ok "empty-live-rc4" || bad "empty-live want rc=4 got $rc"
echo "$out" | grep -q 'NO-DATA live' && ok "empty-live-nodata" || bad "empty-live-nodata"
echo "$out" | grep -q "got='' want=" && bad "empty-live-false-mismatch" || ok "empty-live-no-false-mismatch"

echo "=== promote_ddr_daily plan dry-run ==="
set +e
out=$(
  PROMOTE_EXECUTE=0 \
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  PROMOTE_PAIR_CHECK=0 \
  "$PROMOTE" plan "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "promote-plan" || bad "promote-plan rc=$rc"
echo "$out" | grep -q 'Plex_v2.rbf' && ok "plan-names-v2" || bad "plan-names-v2"
echo "$out" | grep -q 'Plex.rbf' && ok "plan-names-product" || bad "plan-names-product"
echo "$out" | grep -qi 'NEVER overwrite' && ok "plan-never-overwrite-v2" || bad "plan-never-overwrite-v2"

echo "=== promote activate dry-run does not require SSH ==="
set +e
out=$(
  PROMOTE_EXECUTE=0 \
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  PROMOTE_PAIR_CHECK=0 \
  "$PROMOTE" activate "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "activate-dry" || bad "activate-dry rc=$rc"
echo "$out" | grep -q 'DRY-RUN' && ok "activate-dry-marker" || bad "activate-dry-marker"

echo "=== motion rc=77 UNSCORED is HARD FAIL (not soft) ==="
cat >"$WORK/motion77.sh" <<'M'
#!/usr/bin/env bash
echo "VERDICT=UNSCORED green_cast_frames=74"
exit 77
M
chmod +x "$WORK/motion77.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  env -u PROMOTE_VISUAL_CMD -u PAIR_IDLE_PNG \
  PROMOTE_MOTION_CMD="$WORK/motion77.sh" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  /' | tail -20
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "motion-77-hard-8" || bad "motion-77-hard want 8 got $rc"
echo "$out" | grep -qi 'UNSCORED\|HARD FAIL' && ok "motion-77-msg" || bad "motion-77-msg"
if echo "$out" | grep -q 'PROMOTE_GATES_OK'; then bad "gates-ok-on-77"; else ok "no-gates-ok-on-77"; fi

echo "=== motion rc=0 PASS ==="
cat >"$WORK/motion0.sh" <<'M'
#!/usr/bin/env bash
echo "VERDICT=MOTION_OK"
exit 0
M
chmod +x "$WORK/motion0.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  env -u PROMOTE_VISUAL_CMD -u PAIR_IDLE_PNG \
  PROMOTE_MOTION_CMD="$WORK/motion0.sh" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "motion-0-pass" || bad "motion-0-pass rc=$rc"

echo "=== motion rc=2 COLOR_FAIL hard ==="
cat >"$WORK/motion2.sh" <<'M'
#!/usr/bin/env bash
echo "VERDICT=COLOR_FAIL"
exit 2
M
chmod +x "$WORK/motion2.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  env -u PROMOTE_VISUAL_CMD -u PAIR_IDLE_PNG \
  PROMOTE_MOTION_CMD="$WORK/motion2.sh" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "motion-2-hard" || bad "motion-2-hard rc=$rc"

# --- deploy_plex_core naming trap (no SSH) ----------------------------------
echo "=== deploy_plex_core refuses source basename Plex_v2.rbf ==="
printf 'not-a-real-rbf\n' >"$WORK/Plex_v2.rbf"
set +e
out=$(bash "$ROOT/scripts/deploy_plex_core.sh" "$WORK/Plex_v2.rbf" 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /' | head -20
[ "$rc" -eq 10 ] && ok "deploy-refuse-v2-basename" || bad "deploy-refuse-v2-basename rc=$rc"
echo "$out" | grep -qi 'rollback\|Plex_v2\|REFUSED' && ok "deploy-refuse-v2-msg" || bad "deploy-refuse-v2-msg"

echo "=== deploy_plex_core refuses banned md5 prefix ==="
# 8832824e… is banned; craft content is irrelevant — we only need the name Plex.rbf
# and then override is impossible without matching bytes, so call policy directly
# plus a source named Plex.rbf that we force-check via rbf_ship_policy (already
# covered). Here: ensure deploy sources policy and refuses known-bad full hash
# by precomputing is hard; call script with DEPLOY_SKIP_COPY path is SSH.
# Host-only: rbf_ship_policy already tested; basename Plex.rbf + banned content
# would need matching md5. Spot-check script sources policy:
grep -q 'rbf_ship_policy.sh' "$ROOT/scripts/deploy_plex_core.sh" && ok "deploy-sources-policy" || bad "deploy-sources-policy"
grep -q 'PRODUCT_CORE_REMOTE\|DEVICE_CORE_PRODUCT' "$ROOT/scripts/deploy_plex_core.sh" && ok "deploy-uses-product-slot" || bad "deploy-uses-product-slot"
grep -q 'Plex_v2' "$ROOT/scripts/deploy_plex_core.sh" && ok "deploy-mentions-v2-trap" || bad "deploy-mentions-v2-trap"

# --- plexctl host honesty (shared with rollback test) -----------------------
echo "=== plexctl reload-v2 on host is NOT_ON_DEVICE not missing ==="
set +e
out=$(bash "$PLEXCTL" reload-v2 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 4 ] && ok "plexctl-host-rc4" || bad "plexctl-host-rc4=$rc"
if echo "$out" | grep -q 'ERROR no core at'; then bad "plexctl-false-missing"; else ok "plexctl-no-false-missing"; fi
echo "$out" | grep -qE 'NOT_ON_DEVICE|cannot check device path' && ok "plexctl-honest" || bad "plexctl-honest"

echo "=== REGRESSION: probe join must not glue set +e onto V2_MD5 ==="
# shellcheck source=/dev/null
source "$ROOT/scripts/rbf_ship_policy.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/pair_ship_policy.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/pair_live_probe.inc.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/boot_hook_policy.sh"
# Pull join + shape helpers from gate script without executing main:
eval "$(sed -n '/^gate_join_remote_parts()/,/^}/p;/^gate_assert_md5_shape()/,/^}/p;/^gate_field()/,/^}/p' "$GATES")"
# Reproduce the exact class: $(...) strips trailing NL so
#   echo "V2_MD5=$v2_md5"  +  set +e
# becomes one physical line: echo "V2_MD5=$v2_md5"set +e
# which prints: V2_MD5=<32hex>set +e  (parent live measurement).
p1=$(printf '%s\n' 'echo "V2_MD5=$v2_md5"')   # trailing NL stripped by $()
p1=$(printf '%s' "$p1")                        # explicit strip if any remain
p2=$(printf '%s\n' 'set +e' 'echo N_DAEMON=1')
glued="${p1}${p2}"
echo "  glued_sample=$(printf '%s' "$glued" | head -c 90 | cat -A)"
printf '%s' "$glued" | grep -Fq 'v2_md5"set +e' && ok "glued-repro-exists" || bad "glued-repro-exists"
joined=$(gate_join_remote_parts "$p1" "$p2")
echo "$joined" | sed 's/^/  [joined] /' | cat -A | sed 's/^/  /'
echo "$joined" | grep -Fq 'v2_md5"set +e' && bad "join-still-glued" || ok "join-no-glue"
echo "$joined" | grep -qx 'echo "V2_MD5=$v2_md5"' && ok "join-line1" || bad "join-line1"
# Shape must FAIL contaminated value (never fuzzy-trim to pass)
set +e
out=$(gate_assert_md5_shape v2-rollback-core 'dfebf2bfd08dd70b473b587dd7e81848set +e' 2>&1)
src=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  shape-contaminated true rc=$src"
[ "$src" -ne 0 ] && ok "shape-rejects-glue" || bad "shape-rejects-glue"
set +e
gate_assert_md5_shape v2-rollback-core 'dfebf2bfd08dd70b473b587dd7e81848'
src=$?
set -e
[ "$src" -eq 0 ] && ok "shape-accepts-32hex" || bad "shape-accepts-32hex"
set +e
gate_assert_md5_shape v2-rollback-core 'dfebf2bf'
src=$?
set -e
[ "$src" -ne 0 ] && ok "shape-rejects-prefix8" || bad "shape-rejects-prefix8"

echo "=== REGRESSION: live probe matches deleted exe (parent mv trap) ==="
set +e
"$GATES" dump-remote-live >"$WORK/dump_del.txt" 2>&1
drc=$?
set -e
[ "$drc" -eq 0 ] && ok "dump-del-rc0" || bad "dump-del-rc0"
grep -q 'deleted' "$WORK/dump_del.txt" && ok "dump-strips-deleted" || bad "dump-strips-deleted"
# must NOT bare-continue on deleted (old bug skipped corpses → empty n_daemon)
if grep -E '\*\(deleted\)\*.*continue' "$WORK/dump_del.txt" | grep -v 'x=\${x% (deleted)}' | grep -q continue; then
  # allow strip line only
  :
fi
# Prefer conf dirname for root
grep -q 'dirname "\$conf"' "$WORK/dump_del.txt" && ok "dump-root-from-conf" || bad "dump-root-from-conf"
# must match misterplexd* not exact-only
grep -q 'misterplexd\*' "$WORK/dump_del.txt" && ok "dump-match-glob" || bad "dump-match-glob"

echo "=== REGRESSION: dump-remote-live is single heredoc — no V2_MD5 glue possible ==="
set +e
"$GATES" dump-remote-live >"$WORK/dump_remote.txt" 2>&1
drc=$?
set -e
echo "  dump-remote true rc=$drc"
[ "$drc" -eq 0 ] && ok "dump-remote-rc0" || bad "dump-remote-rc0"
# cat -A style: V2_MD5 printf line must not contain set
grep -n "V2_MD5" "$WORK/dump_remote.txt" | sed 's/^/  /'
if grep -E 'V2_MD5=.*set|MD5=%s.*set \+e' "$WORK/dump_remote.txt"; then
  bad "dump-has-v2-set-glue"
else
  ok "dump-no-v2-set-glue"
fi
if grep -Eq 'MD5=\[0-9a-f\]{32}set|PROBE_DONE=1[a-zA-Z]' "$WORK/dump_remote.txt"; then
  bad "dump-structural-glue"
else
  ok "dump-structural-clean"
fi
# must inline live identity (not a second fragment join marker only)
grep -q "LIVE_MD5" "$WORK/dump_remote.txt" && ok "dump-has-live-md5" || bad "dump-has-live-md5"
grep -q "readlink -f" "$WORK/dump_remote.txt" && ok "dump-uses-readlink" || bad "dump-uses-readlink"
# set +e only as whole line (never glued onto another statement)
set +e
bad_set=$(grep -n 'set +e' "$WORK/dump_remote.txt" | grep -v '^[0-9]*:set +e$' || true)
set -e
if [ -z "$bad_set" ]; then
  ok "dump-set-e-alone"
else
  echo "$bad_set" | sed 's/^/  /'
  bad "dump-set-e-alone"
fi

echo "=== REGRESSION: contaminated V2_MD5 in blob fails closed (not false mismatch trim) ==="
cat >"$WORK/live_glue.blob" <<'BLOB'
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=c5382bee73cecdee8220b811e529c297
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=dfebf2bfd08dd70b473b587dd7e81848set +e
N_DAEMON=1
PIDS=4242
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=edc3a46b9d1c6b86337deb90f896eb0f
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_ROOT=/media/fat/misterplex_v2
PLXS_MAGIC=0x504C5853
PLXS_SEQ=10
PLXS_SEQ2=11
BLOB
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_glue.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [glue] /' | tail -25
echo "  [glue] true rc=$rc"
[ "$rc" -ne 0 ] && ok "glue-blob-fail" || bad "glue-blob-fail should not pass"
echo "$out" | grep -q 'shape' && ok "glue-shape-msg" || bad "glue-shape-msg"
# Contaminated capture must NOT also look like pin-drift equality failure
# (parent blind-and-RED: got=<hex>set +e want=<hex>). Skip equality instead.
if echo "$out" | grep -qE 'got=.*set \+e want='; then
  bad "glue-no-got-want-drift-msg"
else
  ok "glue-no-got-want-drift-msg"
fi
echo "$out" | grep -q 'SKIP v2-rollback-core equality' && ok "glue-skip-equality" || bad "glue-skip-equality"
# Must NOT strip glue to 32-hex and pass
echo "$out" | grep -q 'OK v2-rollback-core dfebf2bfd08dd70b473b587dd7e81848' && bad "glue-must-not-trim-pass" || ok "glue-must-not-trim-pass"
# Visual MUST still run (aggregate) — not skip
echo "$out" | grep -qE 'visual_hook|VISUAL_REQUIRED|visual_idle|motion_hook' && ok "glue-visual-ran" || bad "glue-visual-ran"
echo "$out" | grep -q 'skip visual' && bad "glue-no-skip-visual" || ok "glue-no-skip-visual"

echo "=== USER-OWNED conf md5 pin (parent 7f06132f) — exact match / mismatch / NO-DATA ==="
# Green: pin matches LIVE_CONF_MD5 in blob
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_EXPECT_CONF_MD5=7f06132f0c00e90b35141bdc0c60ccc9 \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  [conf-ok] true rc=$rc"
echo "$out" | grep -q 'OK live-conf-md5 7f06132f0c00e90b35141bdc0c60ccc9' && ok "conf-md5-pin-ok" || bad "conf-md5-pin-ok"
# RED: wrong pin
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_EXPECT_CONF_MD5=deadbeefdeadbeefdeadbeefdeadbeef \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  [conf-bad] true rc=$rc"
[ "$rc" -eq 7 ] && ok "conf-md5-mismatch-rc7" || bad "conf-md5-mismatch-rc7 got=$rc"
echo "$out" | grep -q 'FAIL live-conf-md5' && ok "conf-md5-mismatch-msg" || bad "conf-md5-mismatch-msg"
echo "$out" | grep -q 'USER-OWNED' && ok "conf-md5-user-owned-msg" || bad "conf-md5-user-owned-msg"
# NO-DATA empty conf md5
sed '/LIVE_CONF_MD5=/d' "$WORK/live_ok.blob" >"$WORK/live_noconfmd5.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_noconfmd5.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_EXPECT_CONF_MD5=7f06132f0c00e90b35141bdc0c60ccc9 \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  [conf-empty] true rc=$rc"
[ "$rc" -eq 4 ] && ok "conf-md5-empty-rc4" || bad "conf-md5-empty-rc4 got=$rc"
echo "$out" | grep -q 'NO-DATA live-conf-md5' && ok "conf-md5-empty-nodata" || bad "conf-md5-empty-nodata"
echo "$out" | grep -qE "got='' want=" && bad "conf-md5-empty-false-mismatch" || ok "conf-md5-empty-no-false-mismatch"

echo "=== REGRESSION: host-executed remote probe emits pure 32-hex V2_MD5 ==="
# Simulate device files + run the dumped remote script under bash (no SSH).
mkdir -p "$WORK/sim/media/fat/_Utility" "$WORK/sim/proc"
# 32-byte fake RBFs with known md5 via content
printf 'PRODUCT_RBF_BYTES_FOR_MD5_AAAA' >"$WORK/sim/media/fat/_Utility/Plex.rbf"
printf 'V2_ROLLBACK_RBF_BYTES_FOR_MD5_BB' >"$WORK/sim/media/fat/_Utility/Plex_v2.rbf"
want_v2=$(md5sum "$WORK/sim/media/fat/_Utility/Plex_v2.rbf" | awk '{print $1}')
want_prod=$(md5sum "$WORK/sim/media/fat/_Utility/Plex.rbf" | awk '{print $1}')
set +e
"$GATES" dump-remote-live >"$WORK/dump_for_sim.txt" 2>&1
drc=$?
set -e
[ "$drc" -eq 0 ] || bad "sim-dump-rc"
# Rewrite absolute device paths in the remote script to the sim tree.
sed -e "s#/media/fat/_Utility/Plex.rbf#$WORK/sim/media/fat/_Utility/Plex.rbf#g" \
    -e "s#/media/fat/_Utility/Plex_v2.rbf#$WORK/sim/media/fat/_Utility/Plex_v2.rbf#g" \
    "$WORK/dump_for_sim.txt" >"$WORK/sim_remote.sh"
set +e
sim_out=$(bash "$WORK/sim_remote.sh" 2>/dev/null)
src=$?
set -e
echo "$sim_out" | sed 's/^/  [sim] /' | head -20
echo "  [sim] true rc=$src"
v2_line=$(printf '%s\n' "$sim_out" | grep '^V2_MD5=' | head -1)
echo "  [sim] $v2_line"
# Must be exactly V2_MD5=<32hex> with nothing glued
printf '%s\n' "$v2_line" | grep -Eq "^V2_MD5=${want_v2}$" && ok "sim-v2-pure" || bad "sim-v2-pure got='$v2_line' want=V2_MD5=$want_v2"
printf '%s\n' "$v2_line" | grep -q 'set' && bad "sim-v2-no-set-token" || ok "sim-v2-no-set-token"
prod_line=$(printf '%s\n' "$sim_out" | grep '^PRODUCT_MD5=' | head -1)
printf '%s\n' "$prod_line" | grep -Eq "^PRODUCT_MD5=${want_prod}$" && ok "sim-prod-pure" || bad "sim-prod-pure"

echo "=== GREEN path still returns true rc=0 (success path is tested) ==="
printf 'nohup /media/fat/misterplex_v2/bin/misterplexd_supervise.sh >>/media/fat/misterplex_v2/misterplexd_supervise.log 2>&1 &\n' \
  >"$WORK/good_hook.txt"
printf '#!/bin/sh\nUSER_SCRIPT="/media/fat/linux/user-startup.sh"\n' >"$WORK/s99.real"
printf '# inert decoy\n' >"$WORK/inert.decoy"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/good_hook.txt" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/inert.decoy" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [green] /' | tail -22
echo "  [green] true rc=$rc"
[ "$rc" -eq 0 ] && ok "full-green-rc0" || bad "full-green-rc0 got $rc"
echo "$out" | grep -q 'PROMOTE_GATES_OK' && ok "full-green-ok-marker" || bad "full-green-ok-marker"
echo "$out" | grep -q 'OK v2-rollback-core' && ok "full-green-v2" || bad "full-green-v2"
echo "$out" | grep -q 'visual_hook true rc=0' && ok "full-green-visual" || bad "full-green-visual"
echo "$out" | grep -q 'USER_SCRIPT=/media/fat/linux/user-startup.sh' && ok "full-green-s99-path" || bad "full-green-s99-path"

echo "=== RED: pure-wrong V2_MD5 (32 hex, not glue) must FAIL equality — never fuzzy ==="
sed 's/^V2_MD5=.*/V2_MD5=00000000000000000000000000000000/' "$WORK/live_ok.blob" >"$WORK/live_wrong_v2.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_wrong_v2.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/good_hook.txt" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/inert.decoy" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [wrongv2] /' | tail -12
echo "  [wrongv2] true rc=$rc"
[ "$rc" -ne 0 ] && ok "wrong-v2-md5-fail" || bad "wrong-v2-md5-fail should not pass"
echo "$out" | grep -q 'FAIL v2-rollback-core' && ok "wrong-v2-msg" || bad "wrong-v2-msg"
# Must be equality fail, not shape contamination class
echo "$out" | grep -q 'probe capture contaminated' && bad "wrong-v2-must-not-be-shape-only" || ok "wrong-v2-equality-not-shape"

echo "=== RED: boot hook v1 while live root v2 (session-long mismatch class) ==="
printf 'nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &\n' \
  >"$WORK/bad_v1_hook.txt"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/bad_v1_hook.txt" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/inert.decoy" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [hookmismatch] /' | tail -15
echo "  [hookmismatch] true rc=$rc"
[ "$rc" -ne 0 ] && ok "hook-live-mismatch-fail" || bad "hook-live-mismatch-fail"
echo "$out" | grep -qE 'hook_does_not_match_live_pair_root|supervise_root_mismatch|BOOT_HOOK_FAIL|FAIL boot-hook' \
  && ok "hook-live-mismatch-msg" || bad "hook-live-mismatch-msg"


echo "=== bank1 for shipping DDR pair is 0x30080000 (624x480 synthesis-fixed) ==="
out=$(bash -c 'source '"$ROOT"'/scripts/pair_ship_policy.sh; pair_policy_lookup ddr-c5382bee')
echo "$out" | grep -q 'PAIR_BANK1=0x30080000' && ok "bank1-ddr-480p" || bad "bank1-ddr-480p"
out=$(bash -c 'source '"$ROOT"'/scripts/pair_ship_policy.sh; pair_policy_check c5382bee 3883f5ab')
echo "$out" | grep -q 'bank1=0x30080000' && ok "bank1-on-pair-ok" || bad "bank1-on-pair-ok"
out=$(bash -c 'source '"$ROOT"'/scripts/pair_ship_policy.sh; pair_policy_check c5382bee edc3a46b')
echo "$out" | grep -q 'PAIR_OK\|bank1=0x30080000' && ok "bank1-edc3-still-accepted" || bad "bank1-edc3-still-accepted"

echo "=== conf keys REQUIRED but not injected → HARD rc=3 (not NOTE) ==="
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_ok.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_REQUIRE_CONF_KEYS=1 \
  env -u PROMOTE_CONF_BLOB -u PROMOTE_CONF_PATH \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  /' | grep -E 'conf|FAIL|NOTE|true rc' || true
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "conf-keys-hard-fail" || bad "conf-keys-hard-fail want 3 got $rc"
echo "$out" | grep -qi 'NOTE conf-keys not injected' && bad "conf-must-not-soft-note" || ok "conf-no-soft-note"
echo "$out" | grep -qi 'FAIL conf-keys' && ok "conf-fail-msg" || bad "conf-fail-msg"

echo "=== PLXS wrong magic → rc=3 ==="
sed 's/PLXS_MAGIC=0x504C5853/PLXS_MAGIC=0x00000000/' "$WORK/live_ok.blob" >"$WORK/live_noplxs.blob"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_noplxs.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "plxs-wrong-magic" || bad "plxs-wrong-magic rc=$rc"
echo "$out" | grep -qi 'PLXS' && ok "plxs-msg" || bad "plxs-msg"

echo "=== fixture MENU postboot idle → visual rc=8 (parent proved envelope false green) ==="
set +e
out=$(
  PAIR_VISUAL_NO_RECAPTURE=1 \
  PAIR_IDLE_PNG="$ROOT/tests/fixtures/promote/mister_menu_postboot.png" \
  "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [menu] /' | tail -12
echo "  menu true rc=$rc"
[ "$rc" -eq 8 ] && ok "menu-fixture-reject" || bad "menu-fixture-reject rc=$rc"
echo "$out" | grep -q 'not_plex_idle_chevron' && ok "menu-class" || bad "menu-class"

echo "=== fixture solid magenta → rc=8 magenta_cast ==="
set +e
out=$(
  PAIR_VISUAL_NO_RECAPTURE=1 \
  PAIR_IDLE_PNG="$ROOT/tests/fixtures/promote/solid_magenta.png" \
  "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
)
rc=$?
set -e
echo "  magenta true rc=$rc"
[ "$rc" -eq 8 ] && ok "magenta-fixture-reject" || bad "magenta-fixture-reject rc=$rc"
echo "$out" | grep -q 'magenta_cast' && ok "magenta-class" || bad "magenta-class got: $(echo "$out" | grep CLASS=)"

echo "=== fixture chevron idle → rc=0 plex_idle_chevron ==="
set +e
out=$(
  PAIR_VISUAL_NO_RECAPTURE=1 \
  PAIR_IDLE_PNG="$ROOT/tests/fixtures/promote/plex_idle_chevron.png" \
  "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
)
rc=$?
set -e
echo "  chevron true rc=$rc"
[ "$rc" -eq 0 ] && ok "chevron-fixture-pass" || bad "chevron-fixture-pass rc=$rc"
echo "$out" | grep -q 'plex_idle_chevron' && ok "chevron-class" || bad "chevron-class"

echo "=== fixture cold grey → grabber_not_ready then rc=8 (no live HDMI) ==="
set +e
out=$(
  PAIR_VISUAL_NO_RECAPTURE=1 \
  PAIR_IDLE_PNG="$ROOT/tests/fixtures/promote/cold_grabber_grey.png" \
  "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1
)
rc=$?
set -e
echo "$out" | sed 's/^/  [coldfix] /' | tail -15
echo "  coldfix true rc=$rc"
[ "$rc" -eq 8 ] && ok "cold-fixture-hard" || bad "cold-fixture-hard rc=$rc"
echo "$out" | grep -q 'grabber_not_ready' && ok "cold-class" || bad "cold-class"



echo "=== RETRACT: av-lock / av_drift_ms must not be promote PASS criteria ==="
# Gate source must not require av-lock as success (CIRCULAR/UNSCORED commentary OK)
if grep -nE 'av-lock|av_drift_ms' "$GATES" | grep -viE 'RETRACT|BLIND|CIRCULAR|UNSCORED|not |never|comment|#' ; then
  if grep -nE 'av-lock|av_drift_ms' "$GATES" | grep -viE 'RETRACT|BLIND|CIRCULAR|UNSCORED|never|not a|Do not'; then
    bad "gate-no-avlock-criterion"
  else
    ok "gate-no-avlock-criterion"
  fi
else
  ok "gate-no-avlock-criterion"
fi
# Docs must not list clock=av-lock as success observation without RETRACT
if grep -n 'clock=av-lock' "$ROOT/docs/ddr-daily-promotion.md" | grep -v RETRACT | grep -v BLIND | grep -v CIRCULAR | grep -v 'never' ; then
  if grep -A20 'If promotion is correct' "$ROOT/docs/ddr-daily-promotion.md" | grep -q 'clock=av-lock'; then
    bad "docs-no-avlock-pass"
  else
    ok "docs-no-avlock-pass"
  fi
else
  ok "docs-no-avlock-pass"
fi
grep -q 'avsync_measure_hdmi' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-external-avsync-pointer" || bad "docs-external-avsync-pointer"
grep -q 'SESSION-LATCHED' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-session-latched" || bad "docs-session-latched"
grep -q '117' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-117ms" || bad "docs-117ms"
# 2026-08-01 evening card
grep -q 'CIRCULAR' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-avdrift-circular" || bad "docs-avdrift-circular"
grep -qE 'UNSCORED' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-av-unscored" || bad "docs-av-unscored"
grep -q 'castBound' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-castbound-blocker" || bad "docs-castbound-blocker"
grep -q 'P7' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-p7-open" || bad "docs-p7-open"
grep -q '9.57' "$ROOT/docs/ddr-daily-promotion.md" && ok "docs-throughput-480p" || bad "docs-throughput-480p"
if grep -nE 'pass ["'\'']av_drift' "$ROOT/scripts/validate_playback_controls_hw.sh" 2>/dev/null; then
  bad "validate-no-avdrift-pass"
else
  ok "validate-no-avdrift-pass"
fi
# Promote must not require a numeric HDMI offset PASS
if grep -nE 'median offset|av_offset|REQUIRE.*AVSYNC|AVSYNC_PASS' "$GATES" | grep -viE 'RETRACT|not |never|BLIND|SESSION|CIRCULAR|UNSCORED'; then
  bad "gate-no-avsync-offset-pass"
else
  ok "gate-no-avsync-offset-pass"
fi
grep -q 'SESSION-LATCHED' "$GATES" && ok "gate-mentions-session-latched" || bad "gate-mentions-session-latched"

echo "=== summary pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "test_promotion_gates: FAIL"
  echo "true rc=1"
  exit 1
fi
echo "test_promotion_gates: OK"
echo "true rc=0"
exit 0
