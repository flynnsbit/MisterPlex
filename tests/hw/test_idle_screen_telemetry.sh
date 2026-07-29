#!/usr/bin/env bash
# Non-invasive idle/screensaver DDR telemetry probe.
#
# This does not start playback and does not claim HDMI picture PASS. It records
# what the daemon is configured to paint while idle, verifies/provenances the
# resident RBF when EXPECTED_RBF_MD5 is supplied, and samples the active PLXK DDR
# doorbell. It returns 77 for UNSCORED so wrappers cannot treat "not checked" as
# success.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
EXPECTED_RBF_MD5="${EXPECTED_RBF_MD5:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/hw/hw_gate_common.sh
source "$ROOT/tests/hw/hw_gate_common.sh"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@$HOST"
DDR_BASE=$((0x30000000))
DDR_ALIGN=$((256 * 1024))
RC_PASS=0
RC_FAIL=1
RC_UNSCORED=77
RBF_VERIFIED=0

unscored_exit() {
    echo "IDLE_RESULT=UNSCORED reason=$1"
    exit "$RC_UNSCORED"
}

fail_exit() {
    echo "IDLE_RESULT=FAIL reason=$1"
    exit "$RC_FAIL"
}

ssh_read() {
    local out
    if ! out=$($SSH "$1" 2>&1); then
        echo "  UNSCORED: SSH telemetry failed"
        echo "  SSH_OUTPUT: $out"
        unscored_exit "ssh-telemetry-failed"
    fi
    printf '%s' "$out"
}

hex_addr() {
    printf '0x%08X' "$1"
}

devmem_read() {
    ssh_read "devmem $(hex_addr "$1")"
}

derive_ddr_layout_from_plxk() {
    local mult stride doorbell lo hi0 hi1 fmt seq changed score
    local best_score=-1 best_stride=0 best_doorbell=0
    for mult in 1 2 3 4 5 6 7 8; do
        stride=$((DDR_ALIGN * mult))
        doorbell=$((DDR_BASE + stride * 2 - 4096))
        lo="$(devmem_read "$doorbell")"
        [ "$lo" = "0x504C584B" ] || continue
        hi0="$(devmem_read $((doorbell + 4)))"
        sleep 0.2
        hi1="$(devmem_read $((doorbell + 4)))"
        fmt=$(( (hi1 >> 29) & 3 ))
        [ "$fmt" = "1" ] || continue
        seq=$(( hi1 & 0x1fffffff ))
        changed=0
        [ "$hi0" != "$hi1" ] && changed=1
        score=$((changed * 0x20000000 + seq))
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_stride=$stride
            best_doorbell=$doorbell
        fi
    done
    [ "$best_stride" -gt 0 ] || return 1
    DDR_STRIDE=$best_stride
    DDR_DOORBELL=$best_doorbell
    DDR_BANK0=$DDR_BASE
    DDR_BANK1=$((DDR_BASE + DDR_STRIDE))
    return 0
}

echo "IDLE_TELEMETRY_BEGIN"
# Never awk field-1 of line-1: ssh banners yield "**" and misreport a read fault.
RBF_MD5="$(hw_parse_md5_hex "$(ssh_read 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null')")"
echo "RBF resident=${RBF_MD5:-unparsed} expected=${EXPECTED_RBF_MD5:-unset}"
if [ -n "$EXPECTED_RBF_MD5" ]; then
    if [ -z "$RBF_MD5" ]; then
        unscored_exit "rbf-md5-unparsed"
    fi
    EXPECTED_RBF_MD5="$(printf '%s' "$EXPECTED_RBF_MD5" | tr 'A-F' 'a-f')"
    if [ "$RBF_MD5" != "$EXPECTED_RBF_MD5" ]; then
        unscored_exit "rbf-md5-mismatch"
    fi
    RBF_VERIFIED=1
else
    echo "RBF_PROVENANCE_UNVERIFIED=1"
fi

DAEMON_PID="$(ssh_read 'pidof misterplexd 2>/dev/null || echo DEAD')"
[ "$DAEMON_PID" != "DEAD" ] || unscored_exit "daemon-not-running"
echo "DAEMON pid=$DAEMON_PID"

IDLE_CONF="$(ssh_read "awk -F= '/^IDLE_SCREEN=/{print \$2}' /media/fat/misterplex/misterplex.conf 2>/dev/null | tail -1")"
[ -n "$IDLE_CONF" ] || IDLE_CONF="logo"
OSD_CONTROL="$(ssh_read "awk -F= '/^OSD_CONTROL=/{print \$2}' /media/fat/misterplex/misterplex.conf 2>/dev/null | tail -1")"
[ -n "$OSD_CONTROL" ] || OSD_CONTROL="0"
PRESENT_CONF="$(ssh_read "awk -F= '/^PRESENT=/{print \$2}' /media/fat/misterplex/misterplex.conf 2>/dev/null | tail -1")"
[ -n "$PRESENT_CONF" ] || PRESENT_CONF="fb0"
echo "CONFIG idle=$IDLE_CONF osd_control=$OSD_CONTROL present=$PRESENT_CONF"

TIMELINE="$(ssh_read 'wget -qO- "http://127.0.0.1:3005/player/timeline/poll?commandID=wosd-idle-probe" 2>/dev/null || true')"
STATE="$(printf '%s' "$TIMELINE" | sed -n 's/.*state=\"\([^\"]*\)\".*/\1/p' | head -1)"
[ -n "$STATE" ] || STATE="unknown"
echo "TIMELINE state=$STATE"

PLXS_MAGIC=$(devmem_read $((0x3007F100)))
PLXF_MAGIC=$(devmem_read $((0x3007F118)))
PLXD_MAGIC=$(devmem_read $((0x3007F128)))
echo "MAILBOX PLXS=$PLXS_MAGIC PLXF=$PLXF_MAGIC PLXD=$PLXD_MAGIC"
if [ "$PLXS_MAGIC" != "0x504C5853" ] || [ "$PLXF_MAGIC" != "0x504C5846" ] ||
   [ "$PLXD_MAGIC" != "0x504C5844" ]; then
    unscored_exit "mailbox-magic-mismatch"
fi

case "$STATE" in
stopped|unknown) ;;
*)
    echo "IDLE_TELEMETRY_END"
    unscored_exit "playback-active"
    ;;
esac

if ! derive_ddr_layout_from_plxk; then
    unscored_exit "ddr-layout-not-derived"
fi
DDR_DOORBELL_DATA=$((DDR_DOORBELL + 4))
PLXK_T0=$(devmem_read "$DDR_DOORBELL_DATA")
BANK_T0=$(( (PLXK_T0 >> 31) & 1 ))
ACTIVE_BANK=$([ "$BANK_T0" = "1" ] && echo "$DDR_BANK1" || echo "$DDR_BANK0")
ACTIVE_HEX="$(hex_addr "$ACTIVE_BANK")"
W0_T0=$(devmem_read "$ACTIVE_BANK")
W1_T0=$(devmem_read $((ACTIVE_BANK + 4)))
sleep 2
PLXK_T1=$(devmem_read "$DDR_DOORBELL_DATA")
W0_T1=$(devmem_read "$ACTIVE_BANK")
W1_T1=$(devmem_read $((ACTIVE_BANK + 4)))
SEQ_T0=$((PLXK_T0 & 0x1fffffff))
SEQ_T1=$((PLXK_T1 & 0x1fffffff))

echo "DDR stride=$(hex_addr "$DDR_STRIDE") bank0=$(hex_addr "$DDR_BANK0") bank1=$(hex_addr "$DDR_BANK1") doorbell=$(hex_addr "$DDR_DOORBELL")"
echo "PLXK t0=$PLXK_T0 t1=$PLXK_T1 seq0=$SEQ_T0 seq1=$SEQ_T1 active_bank=$BANK_T0 active_addr=$ACTIVE_HEX"
echo "ACTIVE_WORDS t0=$W0_T0,$W1_T0 t1=$W0_T1,$W1_T1"

if [ "$RBF_VERIFIED" != "1" ]; then
    echo "IDLE_TELEMETRY_END"
    unscored_exit "rbf-provenance-unverified"
fi

# Paint-path log bracket (parent RCA: PRESENT=fb0 skipped fpga_.open in initPresent,
# paintIdle never entered the fpga_.ok() block → neither success nor fail logged).
# Evidence class: presence/absence of specific log strings — not HDMI picture.
PAINT_OK_N="$(ssh_read 'grep -c "idle screen painted" /media/fat/misterplex/misterplexd.log 2>/dev/null || echo 0')"
PAINT_FAIL_N="$(ssh_read 'grep -c "idle paint DDR failed\|idle paint failed" /media/fat/misterplex/misterplexd.log 2>/dev/null || echo 0')"
PAINT_OPEN_N="$(ssh_read 'grep -c "idle FPGA frame path OK\|FPGA frame path OK" /media/fat/misterplex/misterplexd.log 2>/dev/null || echo 0')"
PAINT_OK_N=$(printf '%s' "$PAINT_OK_N" | tr -dc '0-9'); PAINT_OK_N=${PAINT_OK_N:-0}
PAINT_FAIL_N=$(printf '%s' "$PAINT_FAIL_N" | tr -dc '0-9'); PAINT_FAIL_N=${PAINT_FAIL_N:-0}
PAINT_OPEN_N=$(printf '%s' "$PAINT_OPEN_N" | tr -dc '0-9'); PAINT_OPEN_N=${PAINT_OPEN_N:-0}
echo "PAINT_LOG painted=$PAINT_OK_N fail=$PAINT_FAIL_N open_ok=$PAINT_OPEN_N"

case "$PRESENT_CONF" in
fpga|both)
    if [ "$PAINT_OK_N" -eq 0 ] && [ "$PAINT_FAIL_N" -eq 0 ]; then
        # Log lacks both bracket lines → paintIdle fpga block never produced a result.
        echo "IDLE_TELEMETRY_END"
        fail_exit "idle-paint-path-silent present=$PRESENT_CONF (no painted/fail log lines)"
    fi
    if [ "$PAINT_OK_N" -eq 0 ] && [ "$PAINT_FAIL_N" -gt 0 ]; then
        echo "IDLE_TELEMETRY_END"
        fail_exit "idle-paint-ddr-failed present=$PRESENT_CONF fail_lines=$PAINT_FAIL_N"
    fi
    ;;
fb0)
    # Core scanout is not driven by fb0 blit alone; without painted/open logs we
    # cannot claim the DDR frame store the core scans was updated.
    if [ "$PAINT_OK_N" -eq 0 ] && [ "$PAINT_OPEN_N" -eq 0 ]; then
        echo "IDLE_TELEMETRY_END"
        unscored_exit "present-fb0-no-fpga-idle-paint-log (core scanout path unproven)"
    fi
    ;;
none)
    unscored_exit "present-none-no-idle-paint"
    ;;
esac

case "$IDLE_CONF" in
black)
    if [ "$W0_T0" != "0x10101010" ] || [ "$W1_T0" != "0x10101010" ]; then
        fail_exit "black-idle-active-bank-not-video-black"
    fi
    ;;
screensaver)
    if [ "$SEQ_T1" -le "$SEQ_T0" ]; then
        fail_exit "screensaver-doorbell-not-advancing"
    fi
    ;;
last|off)
    unscored_exit "last-frame-needs-playback"
    ;;
logo|"")
    # No HDMI capture: picture content unproven. Paint-path + DDR telemetry only.
    if [ "$PAINT_OK_N" -gt 0 ]; then
        echo "IDLE_TELEMETRY_END"
        echo "IDLE_RESULT=PASS scope=idle-paint-log+ddr-telemetry-not-hdmi"
        exit "$RC_PASS"
    fi
    echo "IDLE_TELEMETRY_END"
    echo "IDLE_RESULT=UNSCORED reason=logo-mode-no-paint-log"
    exit "$RC_UNSCORED"
    ;;
*)
    unscored_exit "unknown-idle-mode"
    ;;
esac

echo "IDLE_TELEMETRY_END"
echo "IDLE_RESULT=PASS scope=ddr-idle-telemetry-only"
exit "$RC_PASS"
