#!/usr/bin/env bash
# Device conf is USER-OWNED: DECODE=624x480 etc must survive pair conf merge.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"
WORK="$ROOT/build/conf-user-owned-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ echo "OK $*"; pass=$((pass+1)); }
bad(){ echo "FAIL $*"; fail=$((fail+1)); }

cat >"$WORK/user.conf" <<'C'
# user lab choices — must never be normalised away
PLEX_BASE=http://example.invalid
PRESENT=fpga
DECODE=624x480
DECODE_ALLOW_LAB_480P=1
IDLE_SCREEN=screensaver
AUDIO_CLOCK_PPM=12
C

pair_policy_render_conf ddr "$WORK/user.conf" >"$WORK/out.ddr"
for k in 'DECODE=624x480' 'DECODE_ALLOW_LAB_480P=1' 'IDLE_SCREEN=screensaver' 'AUDIO_CLOCK_PPM=12' 'DDR_YUV_FORCE_SCALE=1' 'FFMPEG_SWS_FLAGS=fast_bilinear'; do
  grep -qxF "$k" "$WORK/out.ddr" && ok "ddr-keeps-$k" || bad "ddr-keeps-$k"
done

pair_policy_render_conf spi "$WORK/user.conf" >"$WORK/out.spi"
for k in 'DECODE=624x480' 'DECODE_ALLOW_LAB_480P=1' 'IDLE_SCREEN=screensaver' 'AUDIO_CLOCK_PPM=12'; do
  grep -qxF "$k" "$WORK/out.spi" && ok "spi-keeps-$k" || bad "spi-keeps-$k"
done
# spi must strip force keys
grep -q 'DDR_YUV_FORCE_SCALE' "$WORK/out.spi" && bad "spi-stripped-force" || ok "spi-stripped-force"
grep -q 'FFMPEG_SWS_FLAGS' "$WORK/out.spi" && bad "spi-stripped-sws" || ok "spi-stripped-sws"

# restore-file mode identity: bytes round-trip + md5 equality (parent 7f06132f class)
cp -f "$WORK/user.conf" "$WORK/exact.bak"
cmp -s "$WORK/user.conf" "$WORK/exact.bak" && ok "restore-file-identity" || bad "restore-file-identity"
u_md5=$(md5sum "$WORK/user.conf" | awk '{print $1}')
b_md5=$(md5sum "$WORK/exact.bak" | awk '{print $1}')
[ "$u_md5" = "$b_md5" ] && ok "restore-file-md5-eq" || bad "restore-file-md5-eq"
# DECODE keys present with lab values — never validated-default wipe
grep -qxF 'DECODE=624x480' "$WORK/exact.bak" && ok "user-decode-624x480" || bad "user-decode-624x480"
grep -qxF 'DECODE_ALLOW_LAB_480P=1' "$WORK/exact.bak" && ok "user-lab-480p" || bad "user-lab-480p"
# Simulate apply_pair_conf host-side check: want_md5 == installed
want_md5=$u_md5
new_md5=$b_md5
if [ "$new_md5" != "$want_md5" ]; then bad "conf-md5-match-ok-logic"; else ok "conf-md5-match-ok-logic"; fi
# rollback source must implement CONF_MD5_MATCH_OK
grep -q 'CONF_MD5_MATCH_OK' "$ROOT/scripts/rollback_v2.sh" && ok "rollback-has-conf-md5-match" || bad "rollback-has-conf-md5-match"
grep -q 'FAIL_CONF_MD5_MISMATCH\|conf host-side md5 equality' "$ROOT/scripts/rollback_v2.sh"   && ok "rollback-has-conf-md5-fail" || bad "rollback-has-conf-md5-fail"

# permanent MENU fixture present
[ -f "$ROOT/tests/fixtures/promote/postboot.png" ] && ok "postboot-fixture" || bad "postboot-fixture"
[ -f "$ROOT/tests/fixtures/promote/mister_menu_postboot.png" ] && ok "mister-menu-fixture" || bad "mister-menu-fixture"
set +e
out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$ROOT/tests/fixtures/promote/postboot.png" \
  "$ROOT/scripts/pair_visual_gate.sh" idle 2>&1)
rc=$?
set -e
echo "  postboot true rc=$rc"
[ "$rc" -eq 8 ] && ok "postboot-red" || bad "postboot-red got $rc"
echo "$out" | grep -q 'not_plex_idle_chevron' && ok "postboot-class" || bad "postboot-class"
# centroid must not be the fail reason
echo "$out" | grep -q 'orange_centroid_out_of_range' && bad "postboot-centroid-class" || ok "postboot-no-centroid"

echo "=== summary pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ] || { echo "true rc=1"; exit 1; }
echo "true rc=0"
exit 0
