#!/usr/bin/env bash
# Deploy runbook for arm-deploy-candidate v4 — execution, not composition.
#
# DEFAULT IS DRY-RUN. Real deploy only when:
#   PARENT_AUTHORIZE_DEPLOY=YES DEPLOY_EXECUTE=1 ./scripts/DEPLOY_V4_RUNBOOK.sh
#
# Pre-registered (publish before measure):
#   wall-clock: 90–180s claim+bounce + 30–60s daemon install + 15s verify  ≈ 2.5–4 min
#   on-box after: CORENAME=Plex, --id misterplex-dev, md5=EXPECT_ARM_MD5
#   RBF unchanged: 41adb98c7a630b541091c22ce291be68
#
# Rollback triggers (act immediately, no deliberation):
#   R1 --id != misterplex-dev (argv or /resources)
#   R2 log: ERROR present path failed | ERROR FPGA SPI unavailable
#   R3 cast frames/presents not advancing when CORENAME=Plex
#   R4 cast entry disappears from Plex after select
# Rollback target ONLY:
#   PREV_BIN=.../backup/misterplexd.before-20260730T013548Z  (f230f95b)
#   NEVER before-20260729T181129 (06c5735a older idle-break)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HYBRID_ROOT="${HYBRID_ROOT:-$(cd "$ROOT/../w-arm-hybrid" 2>/dev/null && pwd -P || true)}"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ID_WANT=misterplex-dev
EXPECT_ARM_MD5="${EXPECT_ARM_MD5:-cd4f422945f50b0267a11290ec9e9adc}"
EXPECT_RBF_MD5="${EXPECT_RBF_MD5:-41adb98c7a630b541091c22ce291be68}"
ROLLBACK_BIN=/media/fat/misterplex/backup/misterplexd.before-20260730T013548Z
ROLLBACK_CONF=/media/fat/misterplex/backup/misterplex.conf.before-20260730T013548Z
CAND_ARM="${CAND_ARM:-$HYBRID_ROOT/build/arm/misterplexd}"
EXECUTE="${DEPLOY_EXECUTE:-0}"
AUTH="${PARENT_AUTHORIZE_DEPLOY:-NO}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }

log "=== DEPLOY V4 RUNBOOK ==="
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
# Architecture belt: must not match known x86 lab hashes
case "$GOT_MD5" in
  8798cec0*|ebb1f220*|1e9a1006*|27cb16d9*|ca6e5647*)
    # ca6e is host bounce2 x86 — never ship
    if file "$CAND_ARM" | grep -q x86; then
      log "FAIL: x86 binary"
      exit 1
    fi
    ;;
esac

log "preflight_ok candidate ARM md5 matches expect"

if [[ "$AUTH" != "YES" || "$EXECUTE" != "1" ]]; then
  log "DRY-RUN only (set PARENT_AUTHORIZE_DEPLOY=YES DEPLOY_EXECUTE=1 to ship)"
  log "Would run:"
  log "  1) no-force claim + visible bounce (Menu→Plex)"
  log "  2) install $CAND_ARM via staged deploy (atomic prev-c2 + .new+mv)"
  log "  3) verify on-box md5==$EXPECT_ARM_MD5 and --id=$ID_WANT"
  log "  4) leave CORENAME=Plex lock released"
  log "  5) on any R1–R4: PREV_BIN=$ROLLBACK_BIN restore (~5–15s)"
  log "pre-registered_duration_s=150..240"
  exit 0
fi

# --- LIVE DEPLOY (parent authorised) ---
T0=$(date +%s)
export MISTER_HOST="$HOST" MISTER_PASS="$PASS" MISTER_USER="$USER"
export MISTERPLEX_ID="$ID_WANT"

# Stage candidate into this tree's build/arm so deploy_misterplexd.sh picks it
# without rebuilding a different tip.
mkdir -p "$ROOT/build/arm"
# Preserve any local arm build
if [[ -f "$ROOT/build/arm/misterplexd" ]]; then
  cp -f "$ROOT/build/arm/misterplexd" "$ROOT/build/arm/misterplexd.pre-v4-local.$$"
fi
cp -f "$CAND_ARM" "$ROOT/build/arm/misterplexd"
chmod +x "$ROOT/build/arm/misterplexd"
STAGE_MD5=$(md5sum "$ROOT/build/arm/misterplexd" | awk '{print $1}')
[[ "$STAGE_MD5" == "$EXPECT_ARM_MD5" ]] || {
  log "FAIL: staged md5 mismatch $STAGE_MD5"
  exit 1
}
log "staged_local_arm_md5=$STAGE_MD5"

# Skip make rebuild of different sources — deploy script always runs make arm-plexd.
# Override by pointing BIN via env if supported; else touch-stamp and use MAKEFLAGS.
# deploy_misterplexd.sh hardcodes make arm-plexd — we need candidate bytes on device.
# Use a wrapper: copy after make OR patch path. Safest: run remote install path only.
#
# Direct path: soft bounce claim, then scp staged binary with deploy script's remote
# half. To avoid make overwriting candidate, set:
export SKIP_ARM_REBUILD=1
# If deploy script ignores SKIP, we install via snapshot of deploy internals:

log "STEP1 claim+visible bounce (CORENAME→Plex)"
# shellcheck disable=SC2086
MISTER_CLAIM_AGENT=w-bounce2-v4 \
  "$ROOT/scripts/mister_soft_bounce.sh" claim \
  --reason "parent-authorised v4 daemon deploy ARM $EXPECT_ARM_MD5" \
  -- bash -c '
    set -euo pipefail
    ROOT="'"$ROOT"'"
    HOST="'"$HOST"'"
    PASS="'"$PASS"'"
    USER="'"$USER"'"
    ID_WANT="'"$ID_WANT"'"
    EXPECT="'"$EXPECT_ARM_MD5"'"
    BIN="'"$ROOT"'/build/arm/misterplexd"
    echo "INSIDE_CLAIM CORENAME=$(cat /tmp/CORENAME 2>/dev/null || true)"
    # Atomic deploy (same contract as deploy_misterplexd.sh post-32f0fa3)
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
      "TAG=before-v4-$(date -u +%Y%m%dT%H%M%SZ) bash -s" <<'"'"'REMOTE_PRE'"'"'
set -euo pipefail
BIN=/media/fat/misterplex/bin/misterplexd
PREV=/media/fat/misterplex/bin/misterplexd.prev-c2
CONF=/media/fat/misterplex/misterplex.conf
BDIR=/media/fat/misterplex/backup
mkdir -p /media/fat/misterplex/bin "$BDIR"
if [[ -f "$BIN" ]]; then
  tmp="${PREV}.new.$$"; cp -f "$BIN" "$tmp"; sync "$tmp" 2>/dev/null || sync || true; mv -f "$tmp" "$PREV"
  bt="$BDIR/misterplexd.${TAG}"; btmp="${bt}.new.$$"; cp -f "$BIN" "$btmp"; sync "$btmp" 2>/dev/null || sync || true; mv -f "$btmp" "$bt"
  if [[ -f "$CONF" ]]; then
    ct="$BDIR/misterplex.conf.${TAG}"; ctmp="${ct}.new.$$"; cp -f "$CONF" "$ctmp"; sync "$ctmp" 2>/dev/null || sync || true; mv -f "$ctmp" "$ct"
  fi
  echo "backup_ok prev=$(md5sum "$PREV" | awk "{print \$1}") snap=$bt"
fi
if pidof misterplexd >/dev/null 2>&1 || pidof ffmpeg >/dev/null 2>&1; then
  kill $(pidof misterplexd ffmpeg 2>/dev/null) 2>/dev/null || true
  sleep 0.4
fi
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
sleep 0.2
REMOTE_PRE
    STAGE=/media/fat/misterplex/bin/misterplexd.new
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" "$USER@$HOST:$STAGE"
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
      "EXPECT='$EXPECT' ID_WANT='$ID_WANT' bash -s" <<'"'"'REMOTE_POST'"'"'
set -euo pipefail
STAGE=/media/fat/misterplex/bin/misterplexd.new
DEST=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
chmod +x "$STAGE"
sync "$STAGE" 2>/dev/null || sync || true
mv -f "$STAGE" "$DEST"
got=$(md5sum "$DEST" | awk "{print \$1}")
echo "onbox_md5=$got"
if [[ "$got" != "$EXPECT" ]]; then
  echo "DEPLOY_FAIL md5 want=$EXPECT got=$got" >&2
  exit 2
fi
# conf product keys — warn only, never silent rewrite
if ! grep -qE "^[[:space:]]*PRESENT=fpga" "$CONF" 2>/dev/null; then
  echo "WARNING: conf missing PRESENT=fpga" >&2
fi
: >/media/fat/misterplex/misterplexd.log
nohup "$DEST" --name MiSTerPlex --id "$ID_WANT" --port 3005 --conf "$CONF" \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.8
ps_line=$(ps w | grep "[m]isterplexd" || true)
echo "daemon_ps=$ps_line"
echo "$ps_line" | grep -qE -- "--id[= ]${ID_WANT}( |$)" || {
  echo "DEPLOY_FAIL id mismatch" >&2
  exit 7
}
res=$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null || true)
echo "$res" | grep -q "machineIdentifier=\"${ID_WANT}\"" || {
  echo "DEPLOY_FAIL resources id" >&2
  exit 7
}
echo "resources_id_ok=$ID_WANT"
echo "CORENAME=$(cat /tmp/CORENAME 2>/dev/null || true)"
rbf=$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | awk "{print \$1}")
echo "rbf_md5=$rbf"
REMOTE_POST
  '

T1=$(date +%s)
log "deploy_wall_s=$((T1 - T0))"
log "DONE — hybrid may run REAL_PMS_VALIDATION_PLAN (CORENAME should be Plex)"
log "Rollback if needed:"
log "  PREV_BIN=$ROLLBACK_BIN PREV_CONF=$ROLLBACK_CONF ./scripts/restore_misterplexd_prev.sh"
