#!/usr/bin/env bash
# Deploy runbook for arm-deploy-candidate v7 — execution, not composition.
#
# DEFAULT IS DRY-RUN. Real deploy only when:
#   PARENT_AUTHORIZE_DEPLOY=YES DEPLOY_EXECUTE=1 ./scripts/DEPLOY_V7_RUNBOOK.sh
#
# See scripts/DEPLOY_V7_PREREGISTER.txt for full predictions (CPU, MENU warn, R1–R7).
#
# Pre-registered:
#   wall-clock: 40–90s (claim+bounce dominates; v4=44s v5=36s)
#   on-box after: CORENAME=Plex, --id misterplex-dev, md5=703b2fd410dd0098089b565e7b9b5167
#   RBF: DO NOT TOUCH (wire6 14eaeff3). Daemon only. conf UNTOUCHED (token).
#   tip: 07ff76a4 = b6071fa doorbell + CORENAME warn (ff72293)
#
# Rollback triggers (immediate):
#   R1 --id != misterplex-dev
#   R2 ERROR present path failed | ERROR FPGA SPI unavailable (on Plex)
#   R3 frames/presents not advancing under CORENAME=Plex
#   R4 cast entry disappears
#   R5 presents stop advancing (baseline AFTER-v5 presents→1728 pfps≈vfps)
#   R6 CORENAME warn while CORENAME=Plex after settle (false positive)
#   R7 CPU combined fpga worse than 131.4 by >5 pts
# Rollback target: prev-c2 expect a56bbc3c (v5). NEVER before-20260729T181129 (06c5735a).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HYBRID_ROOT="${HYBRID_ROOT:-$(cd "$ROOT/../w-arm-hybrid" 2>/dev/null && pwd -P || true)}"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ID_WANT=misterplex-dev
EXPECT_ARM_MD5="${EXPECT_ARM_MD5:-703b2fd410dd0098089b565e7b9b5167}"
EXPECT_RBF_MD5="${EXPECT_RBF_MD5:-14eaeff3270a6f59a434e0f777ed823d}"
# Rollback to live v5 (a56bbc3c) via prev-c2 written at install; never 06c5735a
ROLLBACK_BIN=/media/fat/misterplex/bin/misterplexd.prev-c2
ROLLBACK_MD5_EXPECT=a56bbc3c04863079ac0b29f81c45ceba
CAND_ARM="${CAND_ARM:-$ROOT/build/arm-deploy-v7-freeze/misterplexd}"
# conf: DO NOT REWRITE (preserves PLEX_TOKEN). Daemon binary only.
EXECUTE="${DEPLOY_EXECUTE:-0}"
AUTH="${PARENT_AUTHORIZE_DEPLOY:-NO}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }

log "=== DEPLOY V7 RUNBOOK ==="
log "AUTH=$AUTH EXECUTE=$EXECUTE EXPECT_ARM_MD5=$EXPECT_ARM_MD5"
log "CAND_ARM=$CAND_ARM"

# --- Preflight (always) ---
if [[ ! -f "$CAND_ARM" ]]; then
  log "FAIL: missing candidate ARM binary at $CAND_ARM"
  exit 1
fi
file "$CAND_ARM" | tee /dev/stderr | grep -q 'ARM' || {
  log "FAIL: candidate is not ARM (refusing x86 scp)"
  file "$CAND_ARM"
  exit 1
}
GOT_MD5=$(md5sum "$CAND_ARM" | awk '{print $1}')
log "candidate_md5=$GOT_MD5"
if [[ "$GOT_MD5" != "$EXPECT_ARM_MD5" ]]; then
  log "FAIL: candidate md5 != EXPECT_ARM_MD5 (stale tip?)"
  log "  got=$GOT_MD5 want=$EXPECT_ARM_MD5"
  exit 1
fi
if file "$CAND_ARM" | grep -q x86; then
  log "FAIL: x86 binary"
  exit 1
fi

log "preflight_ok candidate ARM md5 matches expect"

if [[ "$AUTH" != "YES" || "$EXECUTE" != "1" ]]; then
  log "DRY-RUN only (set PARENT_AUTHORIZE_DEPLOY=YES DEPLOY_EXECUTE=1 to ship)"
  log "Would run:"
  log "  1) no-force claim + visible bounce (→Plex)"
  log "  2) install $CAND_ARM via staged deploy (atomic prev-c2 + .new+mv); conf UNTOUCHED"
  log "  3) verify on-box md5==$EXPECT_ARM_MD5 and --id=$ID_WANT"
  log "  4) leave CORENAME=Plex lock released; RBF untouched (observe $EXPECT_RBF_MD5)"
  log "  5) on any R1–R7: PREV_BIN=$ROLLBACK_BIN (expect md5 a56bbc3c v5) restore (~5–15s)"
  log "  6) after verify: MENU warn fire + healthy silence (see DEPLOY_V7_PREREGISTER §3)"
  log "pre-registered_duration_s=40..90"
  exit 0
fi

# --- LIVE DEPLOY (parent authorised) ---
T0=$(date +%s)
export MISTER_HOST="$HOST" MISTER_PASS="$PASS" MISTER_USER="$USER"
export MISTERPLEX_ID="$ID_WANT"

mkdir -p "$ROOT/build/arm"
if [[ -f "$ROOT/build/arm/misterplexd" ]]; then
  cp -f "$ROOT/build/arm/misterplexd" "$ROOT/build/arm/misterplexd.pre-v7-local.$$"
fi
cp -f "$CAND_ARM" "$ROOT/build/arm/misterplexd"
chmod +x "$ROOT/build/arm/misterplexd"
STAGE_MD5=$(md5sum "$ROOT/build/arm/misterplexd" | awk '{print $1}')
[[ "$STAGE_MD5" == "$EXPECT_ARM_MD5" ]] || {
  log "FAIL: staged md5 mismatch $STAGE_MD5"
  exit 1
}
log "staged_local_arm_md5=$STAGE_MD5"

# Helper run inside claim (no nested heredoc quoting hell)
INSTALL_HELPER="$ROOT/build/v7_claim_install.sh"
cat >"$INSTALL_HELPER" <<HELPER
#!/usr/bin/env bash
set -euo pipefail
HOST=${HOST@Q}
PASS=${PASS@Q}
USER=${USER@Q}
ID_WANT=${ID_WANT@Q}
EXPECT=${EXPECT_ARM_MD5@Q}
BIN=${ROOT@Q}/build/arm/misterplexd
WANT_RBF=${EXPECT_RBF_MD5@Q}

echo "INSIDE_CLAIM start"
# CORENAME is on the device; print via ssh for visibility
sshpass -p "\$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "\$USER@\$HOST" 'echo CORENAME_BEFORE=\$(cat /tmp/CORENAME 2>/dev/null || true)'

TAG="before-v7-\$(date -u +%Y%m%dT%H%M%SZ)"
sshpass -p "\$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "\$USER@\$HOST" "TAG='\$TAG' bash -s" <<'REMOTE_PRE'
set -euo pipefail
BIN=/media/fat/misterplex/bin/misterplexd
PREV=/media/fat/misterplex/bin/misterplexd.prev-c2
CONF=/media/fat/misterplex/misterplex.conf
BDIR=/media/fat/misterplex/backup
mkdir -p /media/fat/misterplex/bin "\$BDIR"
if [[ -f "\$BIN" ]]; then
  tmp="\${PREV}.new.\$\$"
  cp -f "\$BIN" "\$tmp"
  sync "\$tmp" 2>/dev/null || sync || true
  mv -f "\$tmp" "\$PREV"
  bt="\$BDIR/misterplexd.\${TAG}"
  btmp="\${bt}.new.\$\$"
  cp -f "\$BIN" "\$btmp"
  sync "\$btmp" 2>/dev/null || sync || true
  mv -f "\$btmp" "\$bt"
  if [[ -f "\$CONF" ]]; then
    ct="\$BDIR/misterplex.conf.\${TAG}"
    ctmp="\${ct}.new.\$\$"
    cp -f "\$CONF" "\$ctmp"
    sync "\$ctmp" 2>/dev/null || sync || true
    mv -f "\$ctmp" "\$ct"
  fi
  echo "backup_ok prev=\$(md5sum "\$PREV" | awk '{print \$1}') snap=\$bt"
fi
# Soft-stop only — never kill -9
if pidof misterplexd >/dev/null 2>&1 || pidof ffmpeg >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  kill \$(pidof misterplexd ffmpeg 2>/dev/null) 2>/dev/null || true
  sleep 0.6
fi
sleep 0.2
REMOTE_PRE

STAGE=/media/fat/misterplex/bin/misterplexd.new
sshpass -p "\$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "\$BIN" "\$USER@\$HOST:\$STAGE"

sshpass -p "\$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "\$USER@\$HOST" "EXPECT='\$EXPECT' ID_WANT='\$ID_WANT' WANT_RBF='\$WANT_RBF' bash -s" <<'REMOTE_POST'
set -euo pipefail
STAGE=/media/fat/misterplex/bin/misterplexd.new
DEST=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
chmod +x "\$STAGE"
sync "\$STAGE" 2>/dev/null || sync || true
mv -f "\$STAGE" "\$DEST"
got=\$(md5sum "\$DEST" | awk '{print \$1}')
echo "onbox_md5=\$got"
if [[ "\$got" != "\$EXPECT" ]]; then
  echo "DEPLOY_FAIL md5 want=\$EXPECT got=\$got" >&2
  exit 2
fi
if ! grep -qE '^[[:space:]]*PRESENT=fpga' "\$CONF" 2>/dev/null; then
  echo "WARNING: conf missing PRESENT=fpga" >&2
fi
: >/media/fat/misterplex/misterplexd.log
nohup "\$DEST" --name MiSTerPlex --id "\$ID_WANT" --port 3005 --conf "\$CONF" \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 1.0
ps_line=\$(ps w | grep '[m]isterplexd' || true)
echo "daemon_ps=\$ps_line"
echo "\$ps_line" | grep -qE -- "--id[= ]\${ID_WANT}( |\$)" || {
  echo "DEPLOY_FAIL id mismatch" >&2
  exit 7
}
# Retry /resources — single wget after sleep 1 raced companion bind (spurious rc=7).
res=""
resources_ok=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  res=\$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null || true)
  if echo "\$res" | grep -q "machineIdentifier=\"\${ID_WANT}\""; then
    resources_ok=1
    echo "resources_attempt=\$attempt ok"
    break
  fi
  echo "resources_attempt=\$attempt empty_or_mismatch"
  sleep 0.2
done
if [[ "\$resources_ok" != "1" ]]; then
  echo "DEPLOY_FAIL resources id after retries" >&2
  exit 7
fi
echo "resources_id_ok=\$ID_WANT"
echo "CORENAME=\$(cat /tmp/CORENAME 2>/dev/null || true)"
rbf=\$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk '{print \$1}')
echo "rbf_md5=\$rbf"
if [[ -n "\$rbf" && -n "\${WANT_RBF:-}" && "\$rbf" != "\$WANT_RBF" ]]; then
  echo "WARNING: RBF md5 changed unexpectedly got=\$rbf want_observe=\$WANT_RBF (not restoring)" >&2
fi
REMOTE_POST

echo "INSIDE_CLAIM install_ok"
HELPER
chmod +x "$INSTALL_HELPER"

log "STEP1 claim+visible bounce (CORENAME→Plex) then daemon install"
MISTER_CLAIM_AGENT=w-bounce2-v7 \
  "$ROOT/scripts/mister_soft_bounce.sh" claim \
  --reason "parent-authorised v7 daemon-only deploy (no conf) ARM ${EXPECT_ARM_MD5}" \
  -- "$INSTALL_HELPER"
claim_rc=$?
echo "claim_install true rc=$claim_rc"
if [[ "$claim_rc" -ne 0 ]]; then
  log "FAIL: claim/install rc=$claim_rc"
  exit "$claim_rc"
fi

T1=$(date +%s)
log "deploy_wall_s=$((T1 - T0))"

# Host-side verify (no token print)
log "STEP2 host-side verify"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "$USER@$HOST" "echo onbox_md5=\$(md5sum /media/fat/misterplex/bin/misterplexd | awk '{print \$1}'); echo CORENAME=\$(cat /tmp/CORENAME 2>/dev/null||true); ps w | grep '[m]isterplexd' || true; wget -qO- http://127.0.0.1:3005/resources 2>/dev/null | head -c 400; echo; echo rbf=\$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk '{print \$1}')"

log "DONE — hand to w-hybrid-arm for post-deploy REAL_PMS (CORENAME=Plex expected)"
log "Rollback if needed:"
log "  PREV_BIN=$ROLLBACK_BIN PREV_CONF=$ROLLBACK_CONF ./scripts/restore_misterplexd_prev.sh"
