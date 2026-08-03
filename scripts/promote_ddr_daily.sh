#!/usr/bin/env bash
# promote_ddr_daily.sh — SAFE promotion of the working DDR pair to product daily.
#
# Parent-measured working pair (2026-07-31 viewed pixels + native 480p):
#   RBF    md5 c5382bee73cecdee8220b811e529c297  → device PRODUCT slot
#          /media/fat/_Utility/Plex.rbf
#   daemon md5 3883f5ab8744e070e7b0820c6b9b4376 — full from pin file after fetch
#          live root from readlink -f /proc/PID/exe (usually misterplex_v2)
#   conf   DDR_YUV_FORCE_SCALE=1 FFMPEG_SWS_FLAGS=fast_bilinear
#          (resolved live --conf from /proc/PID/cmdline — never assume path)
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

# A missing promotion_gate_check.sh is RED (PINNOTFOUND / command-not-found
# family). Never treat bash rc=127 as "opened the gate path successfully".
PROMOTION_GATE_CHECK="$ROOT/scripts/promotion_gate_check.sh"
require_promotion_gate_check() {
  if [ ! -e "$PROMOTION_GATE_CHECK" ]; then
    echo "GATE_MISSING path=$PROMOTION_GATE_CHECK reason=absent"
    echo "A gate that cannot run is HARD FAIL — not a skip, not success."
    echo "true rc=127"
    return 127
  fi
  if [ ! -x "$PROMOTION_GATE_CHECK" ]; then
    echo "GATE_MISSING path=$PROMOTION_GATE_CHECK reason=not_executable"
    echo "A gate that cannot run is HARD FAIL — not a skip, not success."
    echo "true rc=127"
    return 127
  fi
  return 0
}
run_promotion_gate_check() {
  require_promotion_gate_check || return $?
  "$PROMOTION_GATE_CHECK" "$@"
}

default_rbf() {
  local c
  for c in \
    "$ROOT/release_artifacts/ddr-c5382bee-509b0c75/Plex.rbf" \
    "$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/Plex.rbf" \
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
  # Prefer content-addressed pin matching EXPECT_DAEMON_MD5 (gitignored ARM ELF).
  local pin want m
  want=$(printf '%s' "$EXPECT_DAEMON_MD5" | tr -d '[:space:]' | tr 'A-F' 'a-f')
  for pin in \
    "$ROOT/release_artifacts/ddr-c5382bee-509b0c75/misterplexd" \
    "$ROOT/artifacts/daemon-pins/misterplexd.${want:0:8}" \
    "$ROOT/artifacts/daemon-pins/misterplexd.3883f5ab" \
    "$ROOT/artifacts/daemon-pins/misterplexd.edc3a46b" \
    "$ROOT/artifacts/daemon-pins/misterplexd.509b0c75" \
    "$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd" \
    "$ROOT/artifacts/daemon-pins/misterplexd.e9f79de2" \
    "$ROOT/build/arm/misterplexd"
  do
    [ -f "$pin" ] || continue
    m=$(md5sum "$pin" | awk '{print $1}')
    if [ -z "$want" ] || [ "$m" = "$want" ] || [ "${m:0:8}" = "${want:0:8}" ]; then
      # Prefer current DDR prefix over historical pins / unrelated build trees.
      if [ "${want:0:8}" = "3883f5ab" ] && [ "${m:0:8}" != "3883f5ab" ]; then
        continue
      fi
      printf '%s' "$pin"
      return 0
    fi
  done
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

# Fleet 2026-08-01: c5382bee is LAB-OK for experiments, NOT daily-driver ready.
# Vertical 240-row ceiling pixel-proven; frames_done STALE-blind. Override only with
# PROMOTE_ALLOW_KNOWN_DEFECTS=1 after glass re-card breaks solid-field collapse.
refuse_daily_if_not_ready() {
  local core_md5="${1:-$EXPECT_CORE_MD5}"
  if [[ "${PROMOTE_ALLOW_KNOWN_DEFECTS:-0}" == "1" ]]; then
    log "WARN PROMOTE_ALLOW_KNOWN_DEFECTS=1 — parent override; still need viewed pixels"
    return 0
  fi
  set +e
  rbf_policy_daily_promote_ready "$core_md5"
  local rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "REFUSE_DAILY_PROMOTE true rc=$rc"
    echo "true rc=$rc"
    return "$rc"
  fi
  return 0
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

ATOMIC sequence when PROMOTE_EXECUTE=1 (core+daemon+conf as ONE unit):
  1) policy-local (banned/do-not-ship + pin match + pair matrix)
  2) confirm Plex_v2.rbf still SPI pin (NEVER overwrite) — one-step undo core
  3) DEPLOY_LOAD=none deploy_plex_core.sh "\$RBF"
       → disk only: $DEVICE_CORE_PRODUCT = c5382bee (not loaded yet)
  4) PAIR_ID=ddr-c5382bee ROLLBACK_DAEMON="\$DAEMON" \\
       scripts/rollback_v2.sh restore
       → STOP → daemon install → conf DDR keys → ONE menu → start → visual
       → n_daemon via /proc/PID/exe basename==misterplexd (not cmdline/flock)
  5) claim success ONLY if visual/motion rc=0 (77 UNSCORED = hard fail)

Power-cycle worst moments (see: PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh plan):
  - After step 3 only: product file is DDR; live FPGA/daemon still prior pair until 4
  - Mid step 4 after daemon write, before core load: daemon STOPPED (no autostart)
  - Plex_v2.rbf SPI pin always intact as disk undo core

Daemon pins (gitignored — fetch first if missing):
  scripts/fetch_daemon_pins.sh both
  artifacts/daemon-pins/misterplexd.3883f5ab  (DDR PRIMARY 3883f5ab8744…)
  artifacts/daemon-pins/misterplexd.edc3a46b  (DDR rollback)
  artifacts/daemon-pins/misterplexd.e9f79de2  (DDR hist)
  artifacts/daemon-pins/misterplexd.50f4eb92  (SPI)

SPI atomic undo:
  PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \\
    PAIR_IDLE_PNG=/path/idle.png scripts/rollback_v2.sh restore

DO NOT:
  - scripts/restore_misterplexd_prev.sh (DISABLED B8 — half daemon restore)
  - deploy_misterplexd.sh untrusted rebuild path for promote (use named pin + rollback_v2)
  - plexctl reload-v2 on lab host (false MISSING; NOT_ON_DEVICE)
  - confuse Plex.rbf with Plex_v2.rbf
  - claim success on /resources 200 alone (mixed pair is black/green + HTTP 200)
  - ship banned: ${RBF_BANNED_PREFIX8[*]}  do-not-ship: ${RBF_DO_NOT_SHIP_PREFIX8[*]}
  - kill -9 storms / multi menu thrash
EOF
}

cmd_plan() {
  local rbf daemon
  rbf="${1:-$(default_rbf || true)}"
  daemon="${2:-$(default_daemon || true)}"
  print_plan "$rbf" "$daemon"
  echo "--- daily-promote readiness (fleet 2026-08-01) ---"
  set +e
  rbf_policy_daily_promote_ready "$EXPECT_CORE_MD5"
  local ready_rc=$?
  set -e
  echo "rbf_policy_daily_promote_ready true rc=$ready_rc"
  if [ -n "$rbf" ] && [ -n "$daemon" ]; then
    set +e
    run_promotion_gate_check policy-local "$rbf" "$daemon"
    local prc=$?
    set -e
    # Readiness block does not hide pair policy failures or GATE_MISSING.
    if [ "$prc" -ne 0 ]; then
      echo "true rc=$prc"
      return "$prc"
    fi
    # Stamp probe is informational on plan (rc printed); stage/activate hard-refuse.
    set +e
    "$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$daemon"
    local src=$?
    set -e
    echo "daemon_stamp_check true rc=$src"
  else
    echo "NOTE: local artifacts not both present — plan only"
  fi
  # plan stays readable (rc=0) but prints BLOCKER; stage/activate hard-refuse.
  echo "true rc=0"
  return 0
}

cmd_stage() {
  local rbf="${1:-}" daemon="${2:-}"
  rbf="${rbf:-$(default_rbf || true)}"
  daemon="${daemon:-$(default_daemon || true)}"
  print_plan "$rbf" "$daemon"

  refuse_daily_if_not_ready "$EXPECT_CORE_MD5" || return $?

  set +e
  run_promotion_gate_check policy-local "$rbf" "$daemon"
  local prc=$?
  set -e
  if [ "$prc" -ne 0 ]; then
    echo "REFUSE stage: policy-local true rc=$prc"
    echo "true rc=$prc"
    return "$prc"
  fi
  # Untraceable daemons (ea643e99-class content hash only) must not promote.
  set +e
  "$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$daemon"
  local src=$?
  set -e
  if [ "$src" -ne 0 ]; then
    echo "REFUSE stage: daemon_stamp_check true rc=$src (need git_rev stamp, not md5-only)"
    echo "true rc=$src"
    return "$src"
  fi

  if require_execute; then
    log "would: DEPLOY_LOAD=none deploy_plex_core.sh $rbf  (product slot only)"
    log "would: NOT install daemon alone (half-state refuse) — activate uses atomic restore"
    return 0
  fi

  # Stage copies CORE only. Daemon is installed only inside atomic restore
  # so we never leave DDR daemon on disk with SPI core loaded.
  log "stage: copy RBF only (DEPLOY_LOAD=none) → product slot"
  DEPLOY_LOAD=none "$ROOT/scripts/deploy_plex_core.sh" "$rbf"
  local drc=$?
  echo "deploy_plex_core true rc=$drc"
  echo "true rc=$drc"
  return "$drc"
}

cmd_activate() {
  local rbf="${1:-}" daemon="${2:-}"
  rbf="${rbf:-$(default_rbf || true)}"
  daemon="${daemon:-$(default_daemon || true)}"

  print_plan "$rbf" "$daemon"
  refuse_daily_if_not_ready "$EXPECT_CORE_MD5" || return $?

  set +e
  run_promotion_gate_check policy-local "$rbf" "$daemon"
  local prc=$?
  set -e
  if [ "$prc" -ne 0 ]; then
    echo "REFUSE activate: policy-local true rc=$prc"
    echo "true rc=$prc"
    return "$prc"
  fi
  set +e
  "$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$daemon"
  local src=$?
  set -e
  if [ "$src" -ne 0 ]; then
    echo "REFUSE activate: daemon_stamp_check true rc=$src (need git_rev stamp, not md5-only)"
    echo "true rc=$src"
    return "$src"
  fi

  if [ "$EXECUTE" != "1" ]; then
    log "DRY-RUN activate:"
    log "  1) DEPLOY_LOAD=none deploy_plex_core.sh $rbf"
    log "  2) PAIR_ID=ddr-c5382bee ROLLBACK_DAEMON=$daemon scripts/rollback_v2.sh restore"
    log "     (STOP→daemon→conf→ONE menu→start→visual; n_daemon via /proc/exe)"
    PAIR_ID=ddr-c5382bee "$ROOT/scripts/rollback_v2.sh" plan
    echo "true rc=0"
    return 0
  fi

  log "activate step1: stage product core only (Plex_v2 untouched)"
  DEPLOY_LOAD=none "$ROOT/scripts/deploy_plex_core.sh" "$rbf"
  local drc=$?
  echo "deploy_plex_core true rc=$drc"
  if [ "$drc" -ne 0 ]; then
    echo "true rc=$drc"
    return "$drc"
  fi

  log "activate step2: ATOMIC pair restore (daemon+conf+load+start) — never half"
  set +e
  PAIR_ID=ddr-c5382bee \
    ROLLBACK_DAEMON="$daemon" \
    ROLLBACK_EXECUTE=1 \
    "$ROOT/scripts/rollback_v2.sh" restore
  local rrc=$?
  set -e
  echo "atomic_pair_restore true rc=$rrc"
  echo "true rc=$rrc"
  return "$rrc"
}

cmd_verify() {
  run_promotion_gate_check verify-live
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
