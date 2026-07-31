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
# Primary DDR daemon pin is edc3a46b (prefix; full filled after fetch).
EDC_LIVE=edc3a46b9d1c6b86337deb90f896eb0f
cat >"$WORK/live_ok.blob" <<BLOB
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=c5382bee73cecdee8220b811e529c297
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=dfebf2bfd08dd70b473b587dd7e81848
N_DAEMON=1
PIDS=4242
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=$EDC_LIVE
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_ROOT=/media/fat/misterplex_v2
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
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /' | tail -15
[ "$rc" -eq 0 ] && ok "verify-with-visual" || bad "verify-with-visual rc=$rc"
echo "$out" | grep -q 'PROMOTE_GATES_OK' && ok "gates-ok" || bad "gates-ok"
echo "$out" | grep -q 'OK conf-profile=ddr' && ok "conf-ddr-ok" || bad "conf-ddr-ok"

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
BLOB
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/live_mixed.blob" \
  PROMOTE_HTTP="$WORK/fake_http.sh" \
  PROMOTE_VISUAL_CMD="$WORK/visual_ok.sh" \
  PROMOTE_EXPECT_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848 \
  PROMOTE_EXPECT_DAEMON_MD5=e9f79de217982aff44207664fdb945c5 \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
echo "$out" | sed 's/^/  /' | head -30
# expect pair refuse (rc=3) — visual not reached or after pair fail
[ "$rc" -eq 3 ] && ok "mixed-pair-rc3" || bad "mixed-pair want 3 got $rc"
echo "$out" | grep -qi 'PAIR_REFUSE\|pair-compatibility\|spi_core_plus_ddr' && ok "mixed-pair-msg" || bad "mixed-pair-msg"

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

echo "=== summary pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "test_promotion_gates: FAIL"
  echo "true rc=1"
  exit 1
fi
echo "test_promotion_gates: OK"
echo "true rc=0"
exit 0
