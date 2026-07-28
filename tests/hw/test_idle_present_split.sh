#!/usr/bin/env bash
# Split the idle Plex-logo defect between the Linux fb0 path and FPGA F1 path.
#
# This card mutates only PRESENT in the on-device conf, restarts the daemon with
# SIGTERM-by-PID, proves the fb0 path contains the expected logo bytes, restores
# the original PRESENT, records the FPGA bank-release mailbox, then captures the
# actual MiSTer HDMI output locally and classifies no-signal vs valid-black vs
# valid-content. It does not ask a human to look at the screen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
FB0_EXPECT_BG="${FB0_EXPECT_BG:-26_23_1f_ff}"
FB0_EXPECT_FG="${FB0_EXPECT_FG:-0d_a0_e5_ff}"
HDMI_DEV="${HDMI_DEV:-/dev/video0}"
CAPTURE_OUT="${IDLE_CAPTURE_OUT:-$ROOT/build/idle_present_split/hdmi.png}"
CAPTURE_TOOL="$ROOT/scripts/hdmi_capture_classify.py"
RC_FAIL=1
RC_UNSCORED=77

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "$USER@$HOST")

echo "Scope: idle-present split; remotely verifies fb0 logo bytes and FPGA PLXD mailbox, then locally captures HDMI MJPEG 1280x720@60 from $HDMI_DEV and classifies NO_SIGNAL vs VALID_BLACK vs VALID_CONTENT. It does not prove exact Plex-logo shape, decoder correctness, or RBF identity."

set +e
REMOTE_OUT="$("${SSH[@]}" \
    "FB0_EXPECT_BG='$FB0_EXPECT_BG' FB0_EXPECT_FG='$FB0_EXPECT_FG' bash -s" <<'REMOTE'
set -euo pipefail

CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log
RC_FAIL=1
RC_UNSCORED=77

die_fail() {
    echo "IDLE_SPLIT_RESULT=FAIL reason=$1"
    exit "$RC_FAIL"
}

die_unscored() {
    echo "IDLE_SPLIT_RESULT=UNSCORED reason=$1"
    exit "$RC_UNSCORED"
}

conf_value() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k { v=$2 } END { print v }' "$CONF" 2>/dev/null
}

set_present() {
    local mode="$1"
    if grep -q '^PRESENT=' "$CONF" 2>/dev/null; then
        sed -i "s/^PRESENT=.*/PRESENT=$mode/" "$CONF"
    else
        printf '\nPRESENT=%s\n' "$mode" >>"$CONF"
    fi
}

stop_daemon() {
    local pids
    pids="$(pidof misterplexd 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        for p in $pids; do
            kill "$p" 2>/dev/null || true
        done
        sleep 1
    fi
}

start_daemon() {
    nohup /media/fat/misterplex/bin/misterplexd \
        --name MiSTerPlex --id misterplex-dev --port 3005 \
        --conf "$CONF" >>"$LOG" 2>&1 &
    sleep 1
}

pixel_bytes() {
    local x="$1" y="$2" stride="$3" off bytes b0 b1 b2 b3
    off=$((y * stride + x * 4))
    if ! bytes="$(od -An -tx1 -j "$off" -N 4 /dev/fb0 2>/dev/null)"; then
        return 1
    fi
    read -r b0 b1 b2 b3 <<<"$bytes"
    printf '%s_%s_%s_%s' "$b0" "$b1" "$b2" "$b3"
}

decode_plxd() {
    local hi="$1"
    local val=$((hi))
    PLXD_FREE=$((val & 3))
    PLXD_DISP=$(((val >> 2) & 1))
    PLXD_SWAP=$(((val >> 3) & 1))
    PLXD_FRAMES=$(((val >> 16) & 0xffff))
}

ORIG_PRESENT="$(conf_value PRESENT)"
[ -n "$ORIG_PRESENT" ] || ORIG_PRESENT=fb0
RESTORED=0

restore_original() {
    local rc=$?
    set +e
    if [ "$RESTORED" = "0" ]; then
        set_present "$ORIG_PRESENT"
        stop_daemon
        start_daemon
        echo "RESTORED_PRESENT=$(conf_value PRESENT) pid=$(pidof misterplexd 2>/dev/null || echo DEAD)"
        RESTORED=1
    fi
    exit "$rc"
}
trap restore_original EXIT

echo "IDLE_PRESENT_SPLIT_BEGIN orig_present=$ORIG_PRESENT"
echo "CONFIG_SAFE PRESENT=$(conf_value PRESENT) STREAM=$(conf_value STREAM) DECODE=$(conf_value DECODE) IDLE_SCREEN=$(conf_value IDLE_SCREEN) OSD_CONTROL=$(conf_value OSD_CONTROL)"

# Stop any in-flight media before measuring idle. The Web client may keep polling
# as buffering/navigation; that is not used as a pass/fail signal here.
wget -qO- 'http://127.0.0.1:3005/player/playback/stop?commandID=wosd-idle-split-stop' >/dev/null 2>&1 || true
sleep 1

set_present fb0
stop_daemon
start_daemon
sleep 2

FB_SIZE="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true)"
FB_BPP="$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null || true)"
FB_STRIDE="$(cat /sys/class/graphics/fb0/stride 2>/dev/null || true)"
[ -n "$FB_SIZE" ] || die_unscored "fb0-size-unavailable"
[ "$FB_BPP" = "32" ] || die_unscored "fb0-bpp-not-32"
[ -n "$FB_STRIDE" ] || die_unscored "fb0-stride-unavailable"
FB_W="${FB_SIZE%,*}"
FB_H="${FB_SIZE#*,}"
X0=$(((FB_W - 320) / 2))
Y0=$(((FB_H - 240) / 2))
BG_X=$X0
BG_Y=$Y0
FG_X=$((X0 + 120))
FG_Y=$((Y0 + 80))
BG_BYTES="$(pixel_bytes "$BG_X" "$BG_Y" "$FB_STRIDE")" || die_unscored "fb0-bg-read-failed"
FG_BYTES="$(pixel_bytes "$FG_X" "$FG_Y" "$FB_STRIDE")" || die_unscored "fb0-fg-read-failed"
echo "FB0_PROXY bg_xy=${BG_X},${BG_Y} actual=$BG_BYTES expected=$FB0_EXPECT_BG"
echo "FB0_PROXY fg_xy=${FG_X},${FG_Y} actual=$FG_BYTES expected=$FB0_EXPECT_FG"
[ "$BG_BYTES" = "$FB0_EXPECT_BG" ] || die_fail "fb0-logo-background-mismatch"
[ "$FG_BYTES" = "$FB0_EXPECT_FG" ] || die_fail "fb0-logo-foreground-mismatch"
echo "FB0_PROXY=PASS scope=framebuffer-readback-not-hdmi"

set_present "$ORIG_PRESENT"
stop_daemon
start_daemon
RESTORED=1
sleep 2
echo "RESTORED_PRESENT=$(conf_value PRESENT) pid=$(pidof misterplexd 2>/dev/null || echo DEAD)"

PLXD_LO="$(devmem 0x3007F128)"
PLXD_HI="$(devmem 0x3007F12C)"
decode_plxd "$PLXD_HI"
echo "FPGA_PLXD lo=$PLXD_LO hi=$PLXD_HI free_bank_mask=$PLXD_FREE disp_bank=$PLXD_DISP swap_pending=$PLXD_SWAP frames_done=$PLXD_FRAMES"
if [ "$ORIG_PRESENT" = "fpga" ] && [ "$PLXD_LO" = "0x504C5844" ] &&
   [ "$PLXD_FREE" = "0" ] && [ "$PLXD_SWAP" = "1" ]; then
    echo "FPGA_PROXY=BLOCKED_BY_BANK_RELEASE_LIVELOCK scope=mailbox-not-hdmi"
else
    echo "FPGA_PROXY=NOT_CLASSIFIED scope=mailbox-not-hdmi"
fi

echo "IDLE_PRESENT_SPLIT_END"
REMOTE
)"
REMOTE_RC=$?
set -e
printf '%s\n' "$REMOTE_OUT"
if [ "$REMOTE_RC" -ne 0 ]; then
    exit "$REMOTE_RC"
fi

if [ ! -x "$CAPTURE_TOOL" ]; then
    echo "IDLE_SPLIT_RESULT=UNSCORED reason=capture-tool-missing path=$CAPTURE_TOOL"
    exit "$RC_UNSCORED"
fi

mkdir -p "$(dirname "$CAPTURE_OUT")"
set +e
CAPTURE_OUT_TEXT="$(python3 "$CAPTURE_TOOL" --device "$HDMI_DEV" --out "$CAPTURE_OUT" --expect content 2>&1)"
CAPTURE_RC=$?
set -e
printf '%s\n' "$CAPTURE_OUT_TEXT"

if [ "$CAPTURE_RC" -eq 0 ]; then
    echo "HDMI_PROXY=PASS scope=valid-content-not-human-eyes"
    echo "IDLE_SPLIT_RESULT=PASS reason=fb0-logo-bytes-and-hdmi-valid-content"
    exit 0
fi

if [ "$CAPTURE_RC" -eq "$RC_UNSCORED" ]; then
    echo "IDLE_SPLIT_RESULT=UNSCORED reason=hdmi-capture-unavailable-or-busy"
    exit "$RC_UNSCORED"
fi

if grep -q 'HDMI_CAPTURE_RESULT class=VALID_BLACK' <<<"$CAPTURE_OUT_TEXT"; then
    echo "HDMI_PROXY=FAIL scope=valid-frame-but-black"
    echo "IDLE_SPLIT_RESULT=FAIL reason=hdmi-valid-black"
    exit "$RC_FAIL"
fi
if grep -q 'HDMI_CAPTURE_RESULT class=NO_SIGNAL' <<<"$CAPTURE_OUT_TEXT"; then
    echo "HDMI_PROXY=FAIL scope=no-signal-or-invalid-capture-frame"
    echo "IDLE_SPLIT_RESULT=FAIL reason=hdmi-no-signal"
    exit "$RC_FAIL"
fi

echo "IDLE_SPLIT_RESULT=FAIL reason=hdmi-capture-unclassified rc=$CAPTURE_RC"
exit "$RC_FAIL"
