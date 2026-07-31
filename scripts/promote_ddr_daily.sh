#!/usr/bin/env bash
# promote_ddr_daily.sh — SAFE promotion of the working DDR pair to product daily.
#
# Parent-measured working pair (2026-07-31 viewed pixels):
#   RBF    md5 c5382bee73cecdee8220b811e529c297  → device PRODUCT slot
#          /media/fat/_Utility/Plex.rbf
#   daemon md5 e9f79de217982aff44207664fdb945c5
#          live root from readlink -f /proc/PID/exe (usually misterplex_v2)
#
# CRITICAL naming trap:
#   deploy_plex_core.sh writes  /media/fat/_Utility/Plex.rbf     ← PRODUCT
#   daily-driver ROLLBACK is    /media/fat/_Utility/Plex_v2.rbf  ← SPI v0.2.0
#   These are DIFFERENT files. CORENAME always reads "Plex" for both.
#   A/B the wrong path once and you will blame an innocent build.
#
# Rollback (one step, host-side, honest):
#   scripts/rollback_v2.sh restore
#   → menu bounce → load Plex_v2.rbf → plexctl v2
#   Never use plexctl reload-v2 from the lab host (rc=4 NOT_ON_DEVICE).
#
# Safety:
#   - Default is DRY-RUN (plan only). Set PROMOTE_EXECUTE=1 to touch the device.
#   - DEPLOY_LOAD=none|menu only; ONE menu bounce; never kill-9 storms.
#   - Banned / do-not-ship RBF prefixes refused (scripts/rbf_ship_policy.sh).
#   - Never overwrites Plex_v2.rbf.
#   - Daemon install delegates to deploy_misterplexd.sh (named artifact, live exe md5).
#   - Agents must NOT run PROMOTE_EXECUTE=1 (parent owns the device).
#
# Usage:
#   scripts/promote_ddr_daily.sh plan    [rbf] [daemon]
#   scripts/promote_ddr_daily.sh stage   [rbf] [daemon]   # EXECUTE: copy only
#   scripts/promote_ddr_daily.sh activate [rbf] [daemon]  # EXECUTE: stage+menu+daemon
#   scripts/promote_ddr_daily.sh verify
#   scripts/promote_ddr_daily.sh rollback                 # → rollback_v2.sh restore

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=rbf_ship_policy.sh
source "$ROOT/scripts/rbf_ship_policy.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
EXECUTE="${PROMOTE_EXECUTE:-0}"

EXPECT_CORE_MD5="${PROMOTE_EXPECT_CORE_MD5:-$RBF_PIN_DDR_CANDIDATE_FULL}"
EXPECT_DAEMON_MD5="${PROMOTE_EXPECT_DAEMON_MD5:-$DAEMON_PIN_DDR_CANDIDATE_FULL}"

default_rbf() {
  local c
  for c in \
    "$ROOT/fpga/Plex_MiSTer/output_files/Plex.rbf" \
    "$ROOT/fpga/Plex_MiSTer/releases/Plex.rbf" \
    "${MISTER_DEV:-$HOME/Projects/misterfpga-dev}/out/Plex_MiSTer/Plex.rbf"
  do
    if [ -f "$c" ]; then
      local m
      m=$(md5sum "$c" | awk '{print $1}')
      if [ "$m" = "$EXPECT_CORE_MD5" ]; then
        printf '%s' "$c"
        return 0
      fi
    fi
  done
  # Prefer any local file matching pin even outside default paths.
  if [ -n "${PROMOTE_RBF:-}" ] && [ -f "${PROMOTE_RBF}" ]; then
    printf '%s' "$PROMOTE_RBF"
    return 0
  fi
  printf ''
  return 1
}

default_daemon() {
  if [ -n "${PROMOTE_DAEMON:-}" ] && [ -f "${PROMOTE_DAEMON}" ]; then
    printf '%s' "$PROMOTE_DAEMON"
    return 0
  fi
  if [ -f "$ROOT/build/arm/misterplexd" ]; then
    printf '%s' "$ROOT/build/arm/misterplexd"
    return 0
  fi
  printf ''
  return 1
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }

require_execute() {
  if [ "$EXECUTE" != "1" ]; then
    log "DRY-RUN: refusing device mutation (set PROMOTE_EXECUTE=1 for parent-only execute)"
    echo "true rc=0"
    return 0
  fi
  return 1
}

print_plan() {
  local rbf="$1" daemon="$2"
  cat <<EOF
=== DDR daily promotion PLAN ===
HOST                 = $HOST
PROMOTE_EXECUTE      = $EXECUTE  (0=dry-run, 1=parent execute)
PRODUCT core path    = $DEVICE_CORE_PRODUCT
  expect md5         = $EXPECT_CORE_MD5
ROLLBACK core path   = $DEVICE_CORE_V2_DAILY  (NEVER overwrite)
  expect md5         = $RBF_PIN_V2_DAILY_FULL
local RBF            = ${rbf:-"(missing)"}
local daemon         = ${daemon:-"(missing)"}
daemon expect md5    = $EXPECT_DAEMON_MD5

Steps when PROMOTE_EXECUTE=1:
  1) policy-local gates (banned/do-not-ship + pin match + product path)
  2) verify V2 rollback pin still on device (abort if missing/wrong)
  3) DEPLOY_LOAD=none ./scripts/deploy_plex_core.sh "\$RBF"
       → writes ONLY $DEVICE_CORE_PRODUCT (not Plex_v2.rbf)
  4) ./scripts/deploy_misterplexd.sh "\$DAEMON"
       → live root from readlink -f /proc/PID/exe; live exe md5 + n_daemon==1
  5) ONE menu bounce only:
       DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 ./scripts/deploy_plex_core.sh
       (loads menu.rbf then $DEVICE_CORE_PRODUCT — never thrash load_core)
  6) scripts/promotion_gate_check.sh verify-live
       (+ optional PROMOTE_MOTION_CMD for w-instr TREK24 counter; unset = rc=77 incomplete)

Rollback anytime:
  scripts/rollback_v2.sh restore
  → menu → $DEVICE_CORE_V2_DAILY → plexctl v2

DO NOT:
  - run plexctl reload-v2 on the lab host (false MISSING catastrophe; use rollback_v2.sh)
  - confuse Plex.rbf with Plex_v2.rbf
  - ship banned prefixes: ${RBF_BANNED_PREFIX8[*]}
  - ship do-not-ship: ${RBF_DO_NOT_SHIP_PREFIX8[*]}
  - kill -9 storms / multi menu luck thrash
EOF
}

cmd_plan() {
  local rbf daemon
  rbf="${1:-$(default_rbf || true)}"
  daemon="${2:-$(default_daemon || true)}"
  print_plan "$rbf" "$daemon"
  if [ -n "$rbf" ] && [ -n "$daemon" ]; then
    "$ROOT/scripts/promotion_gate_check.sh" policy-local "$rbf" "$daemon"
    return $?
  fi
  echo "NOTE: local artifacts not both present — plan only"
  echo "true rc=0"
  return 0
}

cmd_stage() {
  local rbf="${1:-}" daemon="${2:-}"
  rbf="${rbf:-$(default_rbf || true)}"
  daemon="${daemon:-$(default_daemon || true)}"
  print_plan "$rbf" "$daemon"

  set +e
  "$ROOT/scripts/promotion_gate_check.sh" policy-local "$rbf" "$daemon"
  local prc=$?
  set -e
  if [ "$prc" -ne 0 ]; then
    echo "REFUSE stage: policy-local true rc=$prc"
    echo "true rc=$prc"
    return "$prc"
  fi

  if require_execute; then
    log "would: DEPLOY_LOAD=none deploy_plex_core.sh $rbf"
    log "would: deploy_misterplexd.sh $daemon (no menu bounce in stage)"
    return 0
  fi

  log "stage: copy RBF only (DEPLOY_LOAD=none) → product slot"
  DEPLOY_LOAD=none "$ROOT/scripts/deploy_plex_core.sh" "$rbf"
  local drc=$?
  echo "deploy_plex_core true rc=$drc"
  [ "$drc" -eq 0 ] || { echo "true rc=$drc"; return "$drc"; }

  log "stage: deploy named daemon (live root / live exe md5)"
  DEPLOY_EXPECT_MD5="$EXPECT_DAEMON_MD5" "$ROOT/scripts/deploy_misterplexd.sh" "$daemon"
  local arc=$?
  echo "deploy_misterplexd true rc=$arc"
  echo "true rc=$arc"
  return "$arc"
}

cmd_activate() {
  local rbf="${1:-}" daemon="${2:-}"
  rbf="${rbf:-$(default_rbf || true)}"
  daemon="${daemon:-$(default_daemon || true)}"

  set +e
  cmd_stage "$rbf" "$daemon"
  local src=$?
  set -e
  # dry-run stage returns 0 without execute
  if [ "$EXECUTE" != "1" ]; then
    log "DRY-RUN activate: would ONE menu bounce DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1"
    log "DRY-RUN activate: would promotion_gate_check.sh verify-live"
    echo "true rc=0"
    return 0
  fi
  if [ "$src" -ne 0 ]; then
    echo "REFUSE activate: stage failed true rc=$src"
    echo "true rc=$src"
    return "$src"
  fi

  log "activate: ONE menu bounce (DEPLOY_SKIP_COPY=1 — will not flash a different RBF)"
  DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 "$ROOT/scripts/deploy_plex_core.sh"
  local mrc=$?
  echo "menu_bounce true rc=$mrc"
  if [ "$mrc" -ne 0 ]; then
    echo "MENU bounce failed — consider scripts/rollback_v2.sh restore"
    echo "true rc=$mrc"
    return "$mrc"
  fi

  set +e
  "$ROOT/scripts/promotion_gate_check.sh" verify-live
  local vrc=$?
  set -e
  echo "verify-live true rc=$vrc"
  echo "true rc=$vrc"
  return "$vrc"
}

cmd_verify() {
  "$ROOT/scripts/promotion_gate_check.sh" verify-live
}

cmd_rollback() {
  log "rollback → scripts/rollback_v2.sh restore (host-side honest path)"
  if [ "$EXECUTE" != "1" ]; then
    log "DRY-RUN: would run rollback_v2.sh restore"
    echo "true rc=0"
    return 0
  fi
  "$ROOT/scripts/rollback_v2.sh" restore
}

cmd="${1:-plan}"
shift || true
case "$cmd" in
  plan)     cmd_plan "${1:-}" "${2:-}" ;;
  stage)    cmd_stage "${1:-}" "${2:-}" ;;
  activate) cmd_activate "${1:-}" "${2:-}" ;;
  verify)   cmd_verify ;;
  rollback) cmd_rollback ;;
  *)
    echo "usage: $0 {plan|stage|activate|verify|rollback} [rbf] [daemon]" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
