#!/usr/bin/env bash
# check_hdmi_sink.sh -- is an HDMI sink physically present on the DE10-Nano output?
#
# WHY THIS EXISTS
#   Every "black screen" verdict in this project has been argued from captured
#   pixels. Flat RGB(7,7,7) is emitted by the MS2109 capture dongle for BOTH a
#   black core AND an absent source, so pixels alone cannot settle it. This reads
#   the ADV7513 HDMI transmitter on the board itself, which is upstream of the
#   entire capture chain and independent of it.
#
# BIT DEFINITIONS -- authoritative, not from memory:
#   Linux drivers/gpu/drm/bridge/adv7511/adv7511.h
#     ADV7511_REG_POWER            0x41
#     ADV7511_POWER_POWER_DOWN     BIT(6)
#     ADV7511_REG_STATUS           0x42
#     ADV7511_STATUS_HPD           BIT(6)
#     ADV7511_STATUS_MONITOR_SENSE BIT(5)
#     ADV7511_REG_POWER2           0xd6
#     ADV7511_REG_POWER2_HPD_SRC_MASK 0xc0
#     ADV7511_REG_POWER2_HPD_SRC_NONE 0xc0
#
# SCOPE LIMITS -- read these before quoting a result:
#   1. This proves whether a sink ASSERTS HPD / Rx-sense. It does NOT prove the
#      TMDS output is enabled or disabled. MiSTer sets HPD_SRC=NONE, so the
#      transmitter is told to ignore HPD; a low HPD therefore does not by itself
#      mean the output is off.
#   2. A PASS (sink present) does NOT mean the sink is the capture dongle, nor
#      that anything correct is being transmitted. It is necessary, not sufficient.
#   3. A FAIL means the board sees nothing plugged in and asserting HPD. That
#      makes every concurrent capture verdict unattributable, exactly like the
#      known no-source hash 2358782e.
#
# EXIT CODES
#   0  sink detected (HPD and/or monitor sense asserted)
#   1  no sink detected (both clear) -- captures taken now are unattributable
#   77 UNSCORED: registers unreadable, or the device at 0x39 is not an ADV7513
#   2  usage error
#
# USAGE
#   scripts/check_hdmi_sink.sh
#   scripts/check_hdmi_sink.sh --from-file FIXTURE   # offline, for red/green tests
#
#   FIXTURE format, one "reg value" pair per line, values as 0xNN:
#     0x00 0x13
#     0x41 0x10
#     0x42 0x98
#     0xd6 0xc0

set -uo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER_="${MISTER_USER:-root}"
BUS="${ADV7513_BUS:-1}"
ADDR="${ADV7513_ADDR:-0x39}"
FROM_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,45p' "$0"; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

read_regs_remote() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$USER_@$HOST" "for r in 0x00 0x41 0x42 0xd6; do printf '%s %s\n' \"\$r\" \"\$(i2cget -y $BUS $ADDR \$r 2>/dev/null)\"; done" 2>/dev/null
}

if [ -n "$FROM_FILE" ]; then
  if [ ! -f "$FROM_FILE" ]; then
    echo "Scope: 0 registers (fixture not found: $FROM_FILE)"
    echo "UNSCORED: no data"
    exit 77
  fi
  RAW="$(cat "$FROM_FILE")"
  SRC="fixture:$FROM_FILE"
else
  RAW="$(read_regs_remote)"
  SRC="device:$USER_@$HOST bus$BUS $ADDR"
fi

get() { echo "$RAW" | awk -v r="$1" '$1==r && $2 ~ /^0x[0-9a-fA-F]+$/ {print $2; found=1} END{if(!found) print ""}'; }

REV="$(get 0x00)"; POWER="$(get 0x41)"; STATUS="$(get 0x42)"; POWER2="$(get 0xd6)"

N_OK=0
for v in "$REV" "$POWER" "$STATUS" "$POWER2"; do [ -n "$v" ] && N_OK=$((N_OK+1)); done

echo "Scope: $N_OK/4 ADV7513 registers read from $SRC"

if [ "$N_OK" -eq 0 ]; then
  echo "UNSCORED: no register readable. i2c tooling missing, wrong bus, or device down."
  echo "This is NOT a no-sink verdict."
  exit 77
fi

if [ -z "$REV" ] || [ -z "$STATUS" ]; then
  echo "UNSCORED: chip revision (0x00) or status (0x42) unreadable; cannot decode."
  exit 77
fi

if [ "$((REV))" -ne "$((0x13))" ]; then
  printf 'UNSCORED: 0x00 reads %s, expected 0x13 (ADV7513). Device at %s is not the HDMI transmitter.\n' "$REV" "$ADDR"
  exit 77
fi

S=$((STATUS))
HPD=$(( (S >> 6) & 1 ))
SENSE=$(( (S >> 5) & 1 ))

printf 'reg0x00 chip_rev = %s          -> ADV7513 confirmed\n' "$REV"
printf 'reg0x42 status   = %s          -> HPD(bit6)=%d  MONITOR_SENSE(bit5)=%d\n' "$STATUS" "$HPD" "$SENSE"

if [ -n "$POWER" ]; then
  PD=$(( ($((POWER)) >> 6) & 1 ))
  printf 'reg0x41 power    = %s          -> POWER_DOWN(bit6)=%d (%s)\n' "$POWER" "$PD" \
    "$([ "$PD" -eq 1 ] && echo 'transmitter POWERED DOWN' || echo 'transmitter powered up')"
fi

if [ -n "$POWER2" ]; then
  SRCBITS=$(( $((POWER2)) & 0xc0 ))
  case "$SRCBITS" in
    0)    HS="BOTH (HPD and CEC)" ;;
    64)   HS="HPD pin" ;;
    128)  HS="CEC" ;;
    192)  HS="NONE (HPD ignored by the transmitter)" ;;
    *)    HS="unknown" ;;
  esac
  printf 'reg0xd6 power2   = %s          -> HPD_SRC=%s\n' "$POWER2" "$HS"
fi

echo
if [ "$HPD" -eq 1 ] || [ "$SENSE" -eq 1 ]; then
  echo "SINK_PRESENT: something is connected and asserting HPD/Rx-sense."
  echo "LIMIT: this does not prove the sink is the capture dongle, nor that the"
  echo "LIMIT: transmitted picture is correct. Necessary, not sufficient."
  exit 0
fi

echo "NO_SINK: HPD=0 and MONITOR_SENSE=0. The board sees nothing plugged in"
echo "NO_SINK: and asserting HPD on its HDMI output."
echo "CONSEQUENCE: any HDMI capture taken right now is UNATTRIBUTABLE. Flat"
echo "CONSEQUENCE: RGB(7,7,7) under this condition is a no-source artifact, not"
echo "CONSEQUENCE: evidence about the core. Do not grade it."
echo "CHECK: reseat the HDMI cable at the DE10-Nano, confirm the capture dongle"
echo "CHECK: is powered, and avoid splitters/adapters that do not pass HPD."
echo "LIMIT: HPD_SRC may be NONE, so this does not prove the TMDS output is off."
exit 1
