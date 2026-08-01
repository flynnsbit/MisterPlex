#!/usr/bin/env bash
# restore_misterplexd_prev.sh — ATOMIC pair restore only (B8 half-restore banned).
#
# Parent / rd-review defect (main tree lines ~50-53): the old script copied a
# daemon backup, started it, and exited 0 with ZERO post-conditions. A power
# cycle (or live bank mismatch) then left SPI core + DDR daemon = black screen.
#
# This script NEVER half-restores. It either:
#   A) refuses (rc=10) when PAIR_ID is unset — device untouched, no false OK
#   B) execs scripts/rollback_v2.sh restore which ENFORCES post-conditions:
#        n_daemon==1 via /proc/[pid] + readlink -f exe (not pgrep, not cmdline)
#        live exe md5 == pair daemon pin
#        core disk md5 == pair core pin
#        HTTP :3005/resources == 200|204
#        conf byte-exact when PAIR_CONF_RESTORE_FILE is set (USER-OWNED)
#        boot-hook root matches live pair root
#        visual gate when required (telemetry alone is NOT success)
#
# Usage (parent runs on host; never agent-to-device):
#   PAIR_ID=ddr-c5382bee \
#     ROLLBACK_DAEMON=/media/fat/misterplex_v2/bin/misterplexd.bak.3883f5ab \
#     PAIR_CONF_RESTORE_FILE=./misterplex.conf.userbak \
#     PAIR_IDLE_PNG=/path/idle.png \
#     scripts/restore_misterplexd_prev.sh
#
# Legacy PREV_BIN= is mapped to ROLLBACK_DAEMON when set.
# Exit 10 = REFUSE half-transition / missing pair identity.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLLBACK="$ROOT/scripts/rollback_v2.sh"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,40p' "$0" | sed 's/^# \?//'
  exit 0
fi

# Host-only post-condition gate (mutation-tested). Inject observations:
#   RESTORE_POST_N=1 RESTORE_POST_LIVE_MD5=... RESTORE_POST_EXPECT_DAEMON=...
#   RESTORE_POST_HTTP=200 RESTORE_POST_CONF_LIVE=... RESTORE_POST_CONF_EXPECT=...
#   RESTORE_POST_CORE_LIVE=... RESTORE_POST_CORE_EXPECT=...
#   RESTORE_POST_INI_LIVE=... RESTORE_POST_INI_EXPECT=...
#   scripts/restore_misterplexd_prev.sh verify-post
# Old bug: `md5sum a b || true` discarded mismatch — this path never uses || true.
if [[ "${1:-}" == "verify-post" ]]; then
  set +e
  restore_assert_postconditions \
    "${RESTORE_POST_N:-}" \
    "${RESTORE_POST_LIVE_MD5:-}" \
    "${RESTORE_POST_EXPECT_DAEMON:-}" \
    "${RESTORE_POST_HTTP:-}" \
    "${RESTORE_POST_CONF_LIVE:-}" \
    "${RESTORE_POST_CONF_EXPECT:-}" \
    "${RESTORE_POST_CORE_LIVE:-}" \
    "${RESTORE_POST_CORE_EXPECT:-}" \
    "${RESTORE_POST_INI_LIVE:-}" \
    "${RESTORE_POST_INI_EXPECT:-}"
  rc=$?
  set -e
  echo "restore verify-post true rc=$rc"
  exit "$rc"
fi

# Permanently refuse the old half-restore path (even if someone sets a flag).
if [[ "${RESTORE_ALLOW_HALF:-0}" == "1" ]]; then
  echo "REFUSE HALF_RESTORE: RESTORE_ALLOW_HALF is ignored permanently (B8)." >&2
  echo "true rc=10"
  exit 10
fi

if [[ -z "${PAIR_ID:-}" ]]; then
  cat <<'MSG' >&2
REFUSE HALF_RESTORE: scripts/restore_misterplexd_prev.sh requires PAIR_ID.
  Old behaviour restored daemon bytes only and did NOT restore Plex.rbf /
  enforce live /proc/exe md5 / HTTP :3005 — a false success on the daily driver.

Atomic restore (post-conditions enforced by rollback_v2.sh):

  PAIR_ID=ddr-c5382bee \
    ROLLBACK_DAEMON=/media/fat/misterplex_v2/bin/misterplexd.bak.3883f5ab \
    PAIR_CONF_RESTORE_FILE=/path/to/misterplex.conf.userbak \
    PAIR_IDLE_PNG=/path/to/idle.png \
    scripts/restore_misterplexd_prev.sh

  # SPI daily undo
  PAIR_ID=spi-v2-hybrid \
    ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
    PAIR_IDLE_PNG=/path/to/idle.png \
    scripts/restore_misterplexd_prev.sh

  # Host postcond only (no device):
  RESTORE_POST_N=1 RESTORE_POST_LIVE_MD5=abc RESTORE_POST_EXPECT_DAEMON=abc \
    RESTORE_POST_HTTP=200 RESTORE_POST_CONF_LIVE=x RESTORE_POST_CONF_EXPECT=x \
    scripts/restore_misterplexd_prev.sh verify-post

  # Plan only (no device):
  PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh plan
MSG
  echo "true rc=10"
  exit 10
fi

# Map legacy env from the broken main-tree script.
if [[ -n "${PREV_BIN:-}" && -z "${ROLLBACK_DAEMON:-}" && -z "${PAIR_DAEMON_ARTIFACT:-}" ]]; then
  export ROLLBACK_DAEMON="$PREV_BIN"
  echo "restore: mapped PREV_BIN -> ROLLBACK_DAEMON=$PREV_BIN"
fi

[[ -f "$ROLLBACK" ]] || {
  echo "FAIL missing $ROLLBACK" >&2
  echo "true rc=9"
  exit 9
}

echo "restore: ATOMIC pair PAIR_ID=$PAIR_ID -> rollback_v2.sh restore (post-conditions enforced)"
export ROLLBACK_REQUIRE_VISUAL="${ROLLBACK_REQUIRE_VISUAL:-1}"
exec bash "$ROLLBACK" restore
