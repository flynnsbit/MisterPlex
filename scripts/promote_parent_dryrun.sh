#!/usr/bin/env bash
# promote_parent_dryrun.sh — exact parent commands (NO device touch from this script).
# Prints the hand-sequence + expected md5s for the current healthy pair.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=rbf_ship_policy.sh
source "$ROOT/scripts/rbf_ship_policy.sh"
# shellcheck source=daemon_backup_policy.sh
source "$ROOT/scripts/daemon_backup_policy.sh"

CORE_FULL="${RBF_PIN_DDR_CANDIDATE_FULL:-c5382bee73cecdee8220b811e529c297}"
DAE_FULL="${DAEMON_PIN_DDR_PRIMARY_FULL:-3883f5ab8744e070e7b0820c6b9b4376}"
DAE_P8="${DAE_FULL:0:8}"
CONF_FULL="${PROMOTE_USER_CONF_MD5:-7f06132f0c00e90b35141bdc0c60ccc9}"
HOST="${MISTER_HOST:-192.168.1.183}"

cat <<EOF
=== w-promote PARENT DRY-RUN (read before any device command) ===
worktree: $ROOT
pair: core=${CORE_FULL:0:8} + daemon=${DAE_P8} + conf_user=${CONF_FULL:0:8}
device: $HOST  (parent owns SSH)

--- A) Host unit evidence ---
  bash tests/unit/test_deploy_misterplexd.sh; echo "true rc=\$?"
  bash tests/unit/test_daemon_backup_policy.sh; echo "true rc=\$?"
  bash tests/unit/test_promotion_gates.sh; echo "true rc=\$?"
  bash tests/unit/test_rollback_honest.sh; echo "true rc=\$?"
  bash tests/unit/test_boot_hook_policy.sh; echo "true rc=\$?"

--- B) Pin / policy identity (host) ---
  source scripts/rbf_ship_policy.sh
  echo PRIMARY=\$DAEMON_PIN_DDR_PRIMARY_FULL   # expect $DAE_FULL
  scripts/daemon_backup_policy.sh name-for $DAE_FULL
  scripts/daemon_backup_policy.sh retention-policy
  scripts/daemon_backup_policy.sh inventory-plan

--- C) Device inventory (parent SSH; propose only — never auto-delete) ---
  # Use inventory-plan body on device. Then:
  pid=\$(pidof misterplexd | awk '{print \$1}')
  echo PID=\$pid
  readlink -f /proc/\$pid/exe
  md5sum "\$(readlink -f /proc/\$pid/exe)"   # expect $DAE_FULL
  # conf ONLY from cmdline --conf (never guess misterplex vs misterplex_v2):
  tr '\\0' '\\n' </proc/\$pid/cmdline
  md5sum /media/fat/misterplex_v2/misterplex.conf  # expect $CONF_FULL if that path is live
  md5sum /media/fat/_Utility/Plex.rbf              # expect $CORE_FULL
  md5sum /media/fat/_Utility/Plex_v2.rbf           # expect dfebf2bfd08dd70b473b587dd7e81848

--- D) Daemon-only ship (mechanises parent hand sequence) ---
  HOST_MD5=\$(md5sum path/to/misterplexd | awk '{print \$1}')  # current healthy: $DAE_FULL
  DEPLOY_EXPECT_MD5=\$HOST_MD5 ./scripts/deploy_misterplexd.sh path/to/misterplexd
  # Encoded on-device order (deploy_misterplexd.sh):
  #   1) CAPTURE daemon PIDs (comm/argv0; pidof OK; never pgrep; never cmdline substr)
  #   2) scp -> bin/misterplexd.stage.<host_p8>; md5 STAGED first
  #   3) cp -p live -> misterplexd.bak.<measured_outgoing_p8> (+ misterplexd.<p8>.bak)
  #   4) mv stage onto live (not cp — ETXTBSY)
  #   5) signal ONLY captured PIDs; leave supervisor to restart child
  #   6) verify md5sum \$(readlink -f /proc/NEW/exe) + n_daemon==1
  # Conf is USER-OWNED: missing conf fails rc=8 unless DEPLOY_ALLOW_CREATE_CONF=1

--- E) Atomic pair promote/rollback ---
  PROMOTE_EXECUTE=0 scripts/promote_ddr_daily.sh plan
  PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh plan
  # parent execute only:
  #   PROMOTE_EXECUTE=1 ...
  #   ROLLBACK_EXECUTE=1 PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh restore

--- F) OPEN (do not close) ---
  P1 real power cycle — NOT done
  use scripts/power_cycle_pair_rehearsal.sh checklist only after user OK

--- G) Expected healthy pins ---
  core_product_md5=$CORE_FULL
  daemon_live_md5=$DAE_FULL
  conf_user_md5=$CONF_FULL
  n_daemon=1
  resources_http=200
EOF
echo "true rc=0"
