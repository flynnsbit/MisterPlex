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
# ** CORRECTION 2026-07-28 15:45 -- READ THIS **
#   An earlier version of this script decided sink presence from the HPD and
#   MONITOR_SENSE bits alone and returned NO_SINK on this board. That verdict was
#   WRONG and it was published. MiSTer programs HPD_SRC=NONE (reg 0xd6 = 0xc0),
#   which tells the transmitter to ignore the hot-plug pin; reg 0x42 then reports
#   the qualified source rather than the physical pin, so HPD reads 0 with a sink
#   plainly attached. The EDID proved it: a checksum-valid block naming
#   "HDMI TO USB" -- the MS2109 capture dongle -- was in the chip the whole time.
#
#   The old script even PRINTED the HPD_SRC=NONE caveat and then drew a verdict
#   that caveat forbids. Naming a confound is not the same as applying it.
#
#   Sink presence is now decided by the EDID. HPD/sense are advisory only, and
#   are trusted for a negative verdict solely when HPD sourcing is enabled.
#
# SCOPE LIMITS -- read these before quoting a result:
#   1. A valid EDID proves the transmitter successfully read a sink over DDC at
#      some point SINCE POWER-ON. It does not prove the sink is attached this
#      instant. Bound it with the boot time from /proc/stat btime.
#   2. A PASS does NOT mean anything correct is being transmitted. It is
#      necessary, not sufficient. It DOES identify the sink by name, so it can
#      confirm whether the thing attached is the capture dongle.
#   3. A FAIL means no valid EDID and no HPD assertion. Only then are concurrent
#      captures unattributable, as with the known no-source hash 2358782e.
#
# EXIT CODES
#   0  sink detected (valid EDID, or HPD/sense asserted)
#   1  no sink detected -- captures taken now are unattributable
#   77 UNSCORED: registers unreadable, the device at 0x39 is not an ADV7513, or
#      the EDID is unreadable while HPD_SRC=NONE makes the HPD bit meaningless
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
EDID_ADDR="${ADV7513_EDID_ADDR:-0x3f}"
ADDR="${ADV7513_ADDR:-0x39}"
FROM_FILE=""
EDID_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    --edid-file) EDID_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,45p' "$0"; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

read_regs_remote() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$USER_@$HOST" "for r in 0x00 0x41 0x42 0xd6 0x96; do printf '%s %s\n' \"\$r\" \"\$(i2cget -y $BUS $ADDR \$r 2>/dev/null)\"; done" 2>/dev/null
}

# EDID lives in a SEPARATE i2c map (default 7-bit 0x3f). It is the sink's own
# data, read by the transmitter over DDC -- it cannot be fabricated locally.
read_edid_remote() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$USER_@$HOST" "for r in \$(seq 0 127); do printf '%s ' \"\$(i2cget -y $BUS $EDID_ADDR \$r 2>/dev/null)\"; done; echo" 2>/dev/null
}

if [ -n "$FROM_FILE" ]; then
  if [ ! -f "$FROM_FILE" ]; then
    echo "Scope: 0/5 registers (fixture not found: $FROM_FILE)"
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

REV="$(get 0x00)"; POWER="$(get 0x41)"; STATUS="$(get 0x42)"; POWER2="$(get 0xd6)"; INT0="$(get 0x96)"

N_OK=0
for v in "$REV" "$POWER" "$STATUS" "$POWER2" "$INT0"; do [ -n "$v" ] && N_OK=$((N_OK+1)); done

echo "Scope: $N_OK/5 ADV7513 registers read from $SRC"

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
    192)  HS="NONE (HPD ignored by the transmitter)"; HPD_SRC_NONE=1 ;;
    *)    HS="unknown" ;;
  esac
  printf 'reg0xd6 power2   = %s          -> HPD_SRC=%s\n' "$POWER2" "$HS"
fi

INTV="$(get 0x96)"
if [ -n "$INTV" ]; then
  VS=$(( ($((INTV)) >> 5) & 1 ))
  printf 'reg0x96 int0     = %s          -> VSYNC latched(bit5)=%d (%s)\n' "$INTV" "$VS" \
    "$([ "$VS" -eq 1 ] && echo 'FPGA has delivered vsync to the transmitter' || echo 'no vsync latched since last clear')"
fi

# --- EDID: the deciding test ---------------------------------------------
if [ -n "$EDID_FILE" ]; then
  EDID_RAW="$(cat "$EDID_FILE" 2>/dev/null)"
elif [ -n "$FROM_FILE" ]; then
  EDID_RAW=""
else
  EDID_RAW="$(read_edid_remote)"
fi

EDID_VERDICT="$(EDID_RAW="$EDID_RAW" python3 -c '
import os,sys
raw=os.environ.get("EDID_RAW","").split()
b=[int(v,16) for v in raw if v.startswith("0x")]
if len(b)!=128:
    print(f"UNREADABLE {len(b)}"); sys.exit()
hdr = b[:8]==[0x00,0xff,0xff,0xff,0xff,0xff,0xff,0x00]
csum = sum(b)%256==0
if not (hdr and csum):
    print(f"INVALID hdr={hdr} checksum_ok={csum}"); sys.exit()
m=(b[8]<<8)|b[9]
mfg="".join(chr(((m>>s)&0x1f)+64) for s in (10,5,0))
name=""
for off in (0x36,0x48,0x5a,0x6c):
    d=b[off:off+18]
    if d[0]==0 and d[1]==0 and d[3]==0xfc:
        name=bytes(d[5:18]).decode("ascii","replace").strip()
print(f"VALID {mfg} {name}")
' 2>/dev/null)"

set -- $EDID_VERDICT
EDID_STATE="${1:-UNREADABLE}"

echo
case "$EDID_STATE" in
  VALID)
    shift
    echo "edid: header OK, checksum OK, manufacturer=$1, name=$(echo "${@:2}")"
    echo "SINK_PRESENT: the transmitter has read a valid EDID from an attached sink."
    echo "LIMIT: EDID proves a successful DDC read since power-on, not that the"
    echo "LIMIT: sink is attached this instant. Bound it with /proc/stat btime."
    echo "LIMIT: this says nothing about whether the picture transmitted is correct."
    exit 0 ;;
esac

echo "edid: $EDID_VERDICT"

if [ "$HPD" -eq 1 ] || [ "$SENSE" -eq 1 ]; then
  echo "SINK_PRESENT: no usable EDID, but HPD/Rx-sense is asserted."
  exit 0
fi

if [ "${HPD_SRC_NONE:-0}" = "1" ]; then
  echo "UNSCORED: no usable EDID, and HPD_SRC=NONE makes the HPD bit meaningless"
  echo "UNSCORED: as a presence indicator. This is NOT a no-sink verdict."
  exit 77
fi

echo "NO_SINK: no valid EDID, HPD=0 and MONITOR_SENSE=0, and HPD sourcing is"
echo "NO_SINK: enabled so those bits are meaningful."
echo "CONSEQUENCE: any HDMI capture taken right now is UNATTRIBUTABLE. Flat"
echo "CONSEQUENCE: RGB(7,7,7) under this condition is a no-source artifact, not"
echo "CONSEQUENCE: evidence about the core. Do not grade it."
echo "CHECK: reseat the HDMI cable at the DE10-Nano and confirm the dongle is powered."
exit 1
