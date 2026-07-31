#!/usr/bin/env bash
# Red-team injection suite for promotion_gate_check.sh + pair_visual_gate.sh.
# Parent 2026-07-31: every row must produce its specified rc (host-only, zero device).
# Principle: green = observed right behavior, never "failed to observe one wrong thing".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATES="$ROOT/scripts/promotion_gate_check.sh"
VIS="$ROOT/scripts/pair_visual_gate.sh"
FIX="$ROOT/tests/fixtures/promote"
WORK="$ROOT/build/promote-redteam-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { echo "OK $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

EDC=edc3a46b9d1c6b86337deb90f896eb0f
CORE=c5382bee73cecdee8220b811e529c297
V2=dfebf2bfd08dd70b473b587dd7e81848

cat >"$WORK/base.blob" <<BLOB
PRODUCT_CORE=/media/fat/_Utility/Plex.rbf
PRODUCT_MD5=$CORE
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V2_MD5=$V2
N_DAEMON=1
PIDS=4242
LIVE_EXE=/media/fat/misterplex_v2/bin/misterplexd
LIVE_MD5=$EDC
LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf
LIVE_ROOT=/media/fat/misterplex_v2
PLXS_MAGIC=0x504C5853
PLXS_SEQ=10
PLXS_SEQ2=11
BLOB

cat >"$WORK/conf_ddr.txt" <<'C'
DDR_YUV_FORCE_SCALE=1
FFMPEG_SWS_FLAGS=fast_bilinear
C
cat >"$WORK/http200.sh" <<'H'
#!/usr/bin/env bash
echo 200
H
chmod +x "$WORK/http200.sh"
cat >"$WORK/vis0.sh" <<'V'
#!/usr/bin/env bash
exit 0
V
chmod +x "$WORK/vis0.sh"
printf '#!/bin/sh\nUSER_SCRIPT="/media/fat/linux/user-startup.sh"\n' >"$WORK/s99.real"
printf 'nohup /media/fat/misterplex_v2/bin/misterplexd_supervise.sh >>/media/fat/misterplex_v2/misterplexd_supervise.log 2>&1 &\n' >"$WORK/hook_v2.txt"
printf 'nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &\n' >"$WORK/hook_v1.txt"
printf '# decoy inert\n' >"$WORK/decoy_inert.txt"

run_gate() {
  # shellcheck disable=SC2086
  PROMOTE_GATE_BLOB="$1" \
  PROMOTE_HTTP="$WORK/http200.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis0.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="${2:-$WORK/hook_v2.txt}" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/decoy_inert.txt" \
  "$GATES" verify-live 2>&1
}

echo "=== redteam: product core md5 = v2 pin (mixed pair) → rc=3 ==="
sed "s/PRODUCT_MD5=$CORE/PRODUCT_MD5=$V2/" "$WORK/base.blob" >"$WORK/mixed.blob"
set +e
out=$(run_gate "$WORK/mixed.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "mixed-pair-3" || bad "mixed-pair-3 got $rc"

echo "=== redteam: v2 core MISSING → rc=2 ==="
sed "s/V2_MD5=$V2/V2_MD5=MISSING/" "$WORK/base.blob" >"$WORK/nov2.blob"
set +e
out=$(run_gate "$WORK/nov2.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 2 ] && ok "v2-missing-2" || bad "v2-missing-2 got $rc"

echo "=== redteam: N_DAEMON=2 → rc=9 ==="
sed 's/N_DAEMON=1/N_DAEMON=2/' "$WORK/base.blob" >"$WORK/n2.blob"
set +e
out=$(run_gate "$WORK/n2.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 9 ] && ok "n-daemon-2" || bad "n-daemon-2 got $rc"

echo "=== redteam: N_DAEMON=0 → rc=9 ==="
sed 's/N_DAEMON=1/N_DAEMON=0/' "$WORK/base.blob" >"$WORK/n0.blob"
set +e
out=$(run_gate "$WORK/n0.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 9 ] && ok "n-daemon-0" || bad "n-daemon-0 got $rc"

echo "=== redteam: LIVE_MD5 contaminated (…set +e) → rc=3 ==="
sed "s/LIVE_MD5=$EDC/LIVE_MD5=${EDC}set +e/" "$WORK/base.blob" >"$WORK/contam.blob"
set +e
out=$(run_gate "$WORK/contam.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "live-md5-contam-3" || bad "live-md5-contam-3 got $rc"
echo "$out" | grep -qiE 'shape|md5|FAIL' && ok "contam-msg" || bad "contam-msg"

echo "=== redteam: LIVE_MD5 empty → rc=4 ==="
sed "s/LIVE_MD5=$EDC/LIVE_MD5=/" "$WORK/base.blob" >"$WORK/empty_md5.blob"
set +e
out=$(run_gate "$WORK/empty_md5.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 4 ] && ok "live-md5-empty-4" || bad "live-md5-empty-4 got $rc"

echo "=== redteam: boot hook v1 root → rc=3 ==="
set +e
out=$(run_gate "$WORK/base.blob" "$WORK/hook_v1.txt")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "hook-v1-3" || bad "hook-v1-3 got $rc"

echo "=== redteam: LIVE_CONF empty → rc=9 ==="
sed 's|LIVE_CONF=/media/fat/misterplex_v2/misterplex.conf|LIVE_CONF=|' "$WORK/base.blob" >"$WORK/noconf.blob"
set +e
out=$(run_gate "$WORK/noconf.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 9 ] && ok "live-conf-empty-9" || bad "live-conf-empty-9 got $rc"

echo "=== redteam: http 500 → rc=9 ==="
cat >"$WORK/http500.sh" <<'H'
#!/usr/bin/env bash
echo 500
H
chmod +x "$WORK/http500.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/base.blob" \
  PROMOTE_HTTP="$WORK/http500.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis0.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/hook_v2.txt" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/decoy_inert.txt" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 9 ] && ok "http-500-9" || bad "http-500-9 got $rc"

echo "=== redteam: http empty → rc=4 ==="
cat >"$WORK/http_empty.sh" <<'H'
#!/usr/bin/env bash
echo -n ""
H
chmod +x "$WORK/http_empty.sh"
set +e
out=$(
  PROMOTE_GATE_BLOB="$WORK/base.blob" \
  PROMOTE_HTTP="$WORK/http_empty.sh" \
  PROMOTE_VISUAL_CMD="$WORK/vis0.sh" \
  PROMOTE_CONF_BLOB="$WORK/conf_ddr.txt" \
  PROMOTE_CONF_PROFILE=ddr \
  PROMOTE_S99_BLOB="$WORK/s99.real" \
  PROMOTE_HOOK_BLOB="$WORK/hook_v2.txt" \
  PROMOTE_DECOY_HOOK_BLOB="$WORK/decoy_inert.txt" \
  "$GATES" verify-live 2>&1
)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 4 ] && ok "http-empty-4" || bad "http-empty-4 got $rc"

echo "=== redteam: idle PNG solid green → rc=8 ==="
set +e
out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$FIX/solid_green.png" "$VIS" idle 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "idle-green-8" || bad "idle-green-8 got $rc"

echo "=== redteam: idle PNG solid magenta → rc=8 ==="
set +e
out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$FIX/solid_magenta.png" "$VIS" idle 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "idle-magenta-8" || bad "idle-magenta-8 got $rc"
echo "$out" | grep -q 'magenta_cast' && ok "idle-magenta-class" || bad "idle-magenta-class"

echo "=== redteam: idle PNG cold grey → grabber then rc=8 ==="
set +e
out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$FIX/cold_grabber_grey.png" "$VIS" idle 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "idle-cold-8" || bad "idle-cold-8 got $rc"
echo "$out" | grep -q 'grabber_not_ready' && ok "idle-cold-class" || bad "idle-cold-class"

echo "=== redteam: idle PNG MiSTer MENU (parent proof) → rc=8 ==="
set +e
out=$(PAIR_VISUAL_NO_RECAPTURE=1 PAIR_IDLE_PNG="$FIX/mister_menu_postboot.png" "$VIS" idle 2>&1)
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 8 ] && ok "idle-menu-8" || bad "idle-menu-8 got $rc"
echo "$out" | grep -q 'not_plex_idle_chevron' && ok "idle-menu-class" || bad "idle-menu-class"

echo "=== redteam: control green path → rc=0 ==="
set +e
out=$(run_gate "$WORK/base.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 0 ] && ok "control-green-0" || bad "control-green-0 got $rc"
echo "$out" | grep -q 'PROMOTE_GATES_OK' && ok "control-ok-marker" || bad "control-ok-marker"
echo "$out" | grep -q 'OK PLXS_MAGIC' && ok "control-plxs" || bad "control-plxs"

echo "=== redteam: PLXS missing magic → rc=3 ==="
sed 's/PLXS_MAGIC=0x504C5853/PLXS_MAGIC=MISSING/' "$WORK/base.blob" >"$WORK/noplxs.blob"
set +e
out=$(run_gate "$WORK/noplxs.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "plxs-missing-3" || bad "plxs-missing-3 got $rc"


echo "=== redteam: PLXS magic OK but seq stuck → rc=3 (default advance required) ==="
sed -e 's/PLXS_SEQ=10/PLXS_SEQ=7/' -e 's/PLXS_SEQ2=11/PLXS_SEQ2=7/' "$WORK/base.blob" >"$WORK/stuckseq.blob"
set +e
out=$(run_gate "$WORK/stuckseq.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "plxs-stuck-seq-3" || bad "plxs-stuck-seq-3 got $rc"
echo "$out" | grep -qi 'did not advance\|PLXS_SEQ' && ok "plxs-stuck-msg" || bad "plxs-stuck-msg"

echo "=== redteam: archived v1 REAL-hook body vs v2 live root → rc=3 ==="
# Content of device bak class: _user-startup / real hook with v1 only
printf '%s\n' 'nohup /media/fat/misterplex/bin/misterplexd_supervise.sh >>/media/fat/misterplex/misterplexd_supervise.log 2>&1 &' >"$WORK/hook_v1_archive.txt"
set +e
out=$(run_gate "$WORK/base.blob" "$WORK/hook_v1_archive.txt")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "archive-v1-hook-3" || bad "archive-v1-hook-3 got $rc"
echo "$out" | grep -qi 'boot-hook' && ok "archive-v1-hook-msg" || bad "archive-v1-hook-msg"


echo "=== redteam: V2_MD5 contaminated (…set +e glue class) → rc=3 ==="
sed "s/V2_MD5=$V2/V2_MD5=${V2}set +e/" "$WORK/base.blob" >"$WORK/v2contam.blob"
set +e
out=$(run_gate "$WORK/v2contam.blob")
rc=$?
set -e
echo "  true rc=$rc"
[ "$rc" -eq 3 ] && ok "v2-md5-contam-3" || bad "v2-md5-contam-3 got $rc"
echo "$out" | grep -qi 'shape\|contaminat' && ok "v2-contam-msg" || bad "v2-contam-msg"
# Must NOT fuzzy-match by trimming set +e
echo "$out" | grep -q 'OK v2-rollback-core' && bad "v2-contam-false-ok" || ok "v2-contam-no-false-ok"

echo "=== summary pass=$pass fail=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "test_promotion_redteam: FAIL"
  echo "true rc=1"
  exit 1
fi
echo "test_promotion_redteam: OK"
echo "true rc=0"
exit 0
