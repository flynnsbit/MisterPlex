#!/usr/bin/env bash
# restore_misterplexd_prev.sh — HARD REFUSE (B8 blocker).
#
# Parent 2026-07-31: this script restored ONLY the daemon and left the core
# alone. A DDR daemon with the SPI core (or reverse bank geometry) is a
# BLACK/GREEN screen that still passes file-md5 gates. 320x240 bank1 is
# DDR_BANK1_SPI; 480p bank1 is DDR_BANK1_DDR — mismatched pairs are silent.
#
# DO NOT use this script. Atomic pair restore:
#   PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=/path/idle.png \
#     scripts/rollback_v2.sh restore
#   PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
#     PAIR_IDLE_PNG=/path/idle.png scripts/rollback_v2.sh restore
#
# Exit 10 = REFUSE half-transition; device untouched.

set -euo pipefail

cat <<'MSG' >&2
REFUSE HALF_RESTORE: scripts/restore_misterplexd_prev.sh is disabled (B8).
  It restored daemon bytes only and explicitly did NOT restore Plex.rbf.
  Mixed core+daemon geometry → black/green screen; telemetry can still pass.
  bank1 SPI 320x240 = DDR_BANK1_SPI ; bank1 DDR 480p = DDR_BANK1_DDR

Use ATOMIC pair tools instead (core + daemon + conf together):

  # PRIMARY live DDR recovery (c5382bee + edc3a46b + DDR conf keys):
  PAIR_ID=ddr-c5382bee PAIR_IDLE_PNG=/path/to/idle.png \
    scripts/rollback_v2.sh restore

  # SPI daily undo (dfebf2bf + 50f4eb92; strips DDR_YUV_FORCE_SCALE):
  PAIR_ID=spi-v2-hybrid \
    ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \
    PAIR_IDLE_PNG=/path/to/idle.png \
    scripts/rollback_v2.sh restore

  # Dry-run power-cycle table (no device mutation):
  PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh plan
MSG
echo "true rc=10"
exit 10
