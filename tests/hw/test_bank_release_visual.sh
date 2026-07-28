#!/usr/bin/env bash
# test_bank_release_visual.sh — Human visual verification for bank-release fix
#
# Runs automated telemetry checks over SSH, then prints a discriminating
# questionnaire for the human observer. The human answers ONLY what a screen
# uniquely provides; all telemetry is captured by us.
#
# IMPORTANT: The picture on this screen is produced by the ARM decoder (FFmpeg).
# This test verifies the DISPLAY PATH (DDR frame store → HDMI scanout), NOT
# FPGA decode. A pass here does NOT advance decode-off-ARM.
#
# Usage: MISTER_HOST=192.168.1.183 MISTER_PASS=1 ./tests/hw/test_bank_release_visual.sh
#
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no root@$HOST"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  BANK-RELEASE VISUAL VERIFICATION — HUMAN TEST CARD            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── PROVENANCE ───────────────────────────────────────────────────────────────
echo "━━━ PROVENANCE (automated) ━━━"
RBF_MD5=$($SSH 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' | awk '{print $1}')
echo "  Resident RBF md5: $RBF_MD5"
echo "  Capture time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
echo ""

# ─── PRE-FLIGHT (automated) ──────────────────────────────────────────────────
echo "━━━ PRE-FLIGHT CHECKS (automated) ━━━"

# Daemon alive?
DAEMON_PID=$($SSH 'pidof misterplexd 2>/dev/null || echo DEAD')
if [ "$DAEMON_PID" = "DEAD" ]; then
    echo "  ✗ Daemon not running — ABORT"
    exit 1
fi
echo "  ✓ Daemon running (PID $DAEMON_PID)"

# Mailbox state
PLXS_MAGIC=$($SSH 'devmem 0x3007F100')
PLXF_MAGIC=$($SSH 'devmem 0x3007F118')
PLXD_MAGIC=$($SSH 'devmem 0x3007F128')
echo "  PLXS magic: $PLXS_MAGIC (expect 0x504C5853)"
echo "  PLXF magic: $PLXF_MAGIC (expect 0x504C5846)"
echo "  PLXD magic: $PLXD_MAGIC (expect 0x504C5844)"

if [ "$PLXS_MAGIC" = "0x00000000" ]; then
    echo "  ✗ FPGA mailboxes are zero — core not running. ABORT."
    exit 1
fi
echo ""

# ─── START PLAYBACK (automated) ──────────────────────────────────────────────
echo "━━━ STARTING PLAYBACK (automated) ━━━"
$SSH "curl -s 'http://127.0.0.1:3005/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F9&offset=0&address=192.168.1.41&port=32400&protocol=http&token=XW6Xx-T7srtBzgwYmxFP&commandID=99'" >/dev/null 2>&1
echo "  Playback started (ratingKey=9, 1080p→480p transcode)"
echo "  Waiting 5 seconds for frames to flow..."
sleep 5

# ─── TELEMETRY UNDER LOAD (automated) ────────────────────────────────────────
echo ""
echo "━━━ TELEMETRY UNDER LOAD (automated) ━━━"

# Two PLXD reads 2 seconds apart
PLXD_T0=$($SSH 'devmem 0x3007F12C')
PLXK_T0=$($SSH 'devmem 0x300FF004')
sleep 2
PLXD_T1=$($SSH 'devmem 0x3007F12C')
PLXK_T1=$($SSH 'devmem 0x300FF004')

echo "  PLXD data t=0: $PLXD_T0"
echo "  PLXD data t=2: $PLXD_T1"
echo "  PLXK data t=0: $PLXK_T0"
echo "  PLXK data t=2: $PLXK_T1"

# Decode PLXD fields
decode_plxd() {
    local val=$((${1}))
    local free_mask=$((val & 3))
    local disp_bank=$(( (val >> 2) & 1 ))
    local swap_pend=$(( (val >> 3) & 1 ))
    local frames=$(( (val >> 16) & 0xFFFF ))
    echo "free_bank_mask=$free_mask disp_bank=$disp_bank swap_pending=$swap_pend frames_done=$frames"
}

echo "  PLXD t=0 decoded: $(decode_plxd $PLXD_T0)"
echo "  PLXD t=2 decoded: $(decode_plxd $PLXD_T1)"
echo ""

# Check for the specific defect pattern
SWAP_T0=$(( (${PLXD_T0} >> 3) & 1 ))
DISP_T0=$(( (${PLXD_T0} >> 2) & 1 ))
FREE_T0=$(( ${PLXD_T0} & 3 ))
FRAMES_T0=$(( (${PLXD_T0} >> 16) & 0xFFFF ))
FRAMES_T1=$(( (${PLXD_T1} >> 16) & 0xFFFF ))

if [ "$SWAP_T0" = "1" ] && [ "$FREE_T0" = "0" ]; then
    echo "  ⚠ KNOWN DEFECT PATTERN: swap_pending=1, free_bank_mask=0"
    echo "    Display is likely frozen on bank $DISP_T0 (not swapping)."
    echo "    Human should see STATIC image, not moving video."
elif [ "$((FRAMES_T1 - FRAMES_T0))" -gt "0" ] && [ "$FREE_T0" -gt "0" ]; then
    echo "  ✓ Bank release appears functional (frames advancing, free_mask>0)"
    echo "    Human should see MOVING video."
fi
echo ""

# Bank content check
echo "━━━ BANK CONTENT (automated) ━━━"
BANK0_W0=$($SSH 'devmem 0x30000000')
BANK0_W1=$($SSH 'devmem 0x30000004')
BANK1_W0=$($SSH 'devmem 0x30080000')
BANK1_W1=$($SSH 'devmem 0x30080004')
echo "  Bank 0 [0:7]: $BANK0_W0 $BANK0_W1"
echo "  Bank 1 [0:7]: $BANK1_W0 $BANK1_W1"

if [ "$BANK0_W0" = "$BANK1_W0" ] && [ "$BANK0_W0" = "0x2D2D2D2D" ]; then
    echo "  ⚠ Both banks contain idle-painter gray (0x2D). No video content visible."
elif [ "$BANK0_W0" != "$BANK1_W0" ]; then
    echo "  ✓ Banks differ — double-buffering may be active."
fi
echo ""

# Grab last stats line from daemon
STATS=$($SSH 'grep "pfps=" /media/fat/misterplex/misterplexd.log | tail -1')
echo "  Last stats: $STATS"
echo ""

# ─── HUMAN QUESTIONNAIRE ─────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  HUMAN OBSERVER — PLEASE ANSWER THESE QUESTIONS                ║"
echo "║  (Look at the MiSTer HDMI output RIGHT NOW)                    ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║                                                                ║"
echo "║  RBF: $RBF_MD5                          ║"
echo "║                                                                ║"
echo "║  Q1. MOTION: Is the image...                                   ║"
echo "║      A) Moving (video playing normally)                        ║"
echo "║      B) Frozen/static (single still image)                     ║"
echo "║      C) Black screen / no signal                               ║"
echo "║      D) MiSTer menu / OSD (not our core)                       ║"
echo "║                                                                ║"
echo "║  Q2. TEARING: Do you see... (LOOK CAREFULLY)                   ║"
echo "║      A) Clean motion, no splits                                ║"
echo "║      B) Horizontal line where top/bottom halves don't match    ║"
echo "║      C) Image flickers between two different frames            ║"
echo "║      D) Diagonal tearing / shearing during motion              ║"
echo "║      → B/C/D = bank race confirmed (the defect we are hunting)║"
echo "║                                                                ║"
echo "║  Q3. COLOUR: The video content is a movie scene. Are colours...║"
echo "║      A) Normal (skin tones, correct hues)                      ║"
echo "║      B) All green / pink / purple tint                         ║"
echo "║      C) Blue-and-red swap (faces look blue)                    ║"
echo "║      D) Grayscale / washed out                                 ║"
echo "║      E) Uniform dark gray (no recognizable content)            ║"
echo "║      → E = display frozen on idle painter (known pre-fix)      ║"
echo "║      → B/C = channel swap or YUV coefficient error             ║"
echo "║                                                                ║"
echo "║  Q4. GEOMETRY: Does the image...                               ║"
echo "║      A) Fill the screen properly (maybe small black bars)      ║"
echo "║      B) Have a large black area on one side                    ║"
echo "║      C) Look stretched or squished                             ║"
echo "║      D) Show content shifted/offset from center                ║"
echo "║                                                                ║"
echo "║  Q5. AUDIO: Is there...                                        ║"
echo "║      A) Audio playing, in sync with video                      ║"
echo "║      B) Audio playing, but ahead/behind video                  ║"
echo "║      C) No audio                                               ║"
echo "║      D) Audio stuttering / crackling                           ║"
echo "║                                                                ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  WHAT A PASS LOOKS LIKE:                                       ║"
echo "║    Q1=A, Q2=A, Q3=A, Q4=A, Q5=A or Q5=B                       ║"
echo "║    (Minor lip-sync drift is acceptable; tearing is NOT)        ║"
echo "║                                                                ║"
echo "║  EXPECTED FAILURES ON THE KNOWN DEFECT (pre bank-release fix): ║"
echo "║    Q1=B + Q3=E = display frozen on idle painter bank           ║"
echo "║    Q1=A + Q2=B/C = bank-release race (ARM overwrites active)   ║"
echo "║                                                                ║"
echo "║  ⚠ CAVEAT: This picture is ARM-decoded (FFmpeg). It does NOT   ║"
echo "║  prove FPGA decode. A pass here means the display path works.  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Please reply with: Q1=_ Q2=_ Q3=_ Q4=_ Q5=_"
echo ""

# ─── STOP PLAYBACK after 60s (cleanup) ───────────────────────────────────────
echo "(Playback will auto-stop at content end. To stop early: curl http://$HOST:3005/player/playback/stop)"
