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
TOKEN="${PLEX_TOKEN:-${MISTERPLEX_TOKEN:-}}"
EXPECTED_RBF_MD5="${EXPECTED_RBF_MD5:-}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@$HOST"
DDR_BASE=$((0x30000000))
DDR_ALIGN=$((256 * 1024))
RBF_VERIFIED=0

unscored_exit() {
    echo "HUMAN_RESULT=UNSCORED reason=$1"
    exit 0
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
        # Prefer a doorbell that is actively advancing; stale PLXK words from a
        # previous geometry can legally remain in DDR and must not win merely
        # because their magic is present.
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

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  BANK-RELEASE VISUAL VERIFICATION — HUMAN TEST CARD            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── PROVENANCE ───────────────────────────────────────────────────────────────
echo "━━━ PROVENANCE (automated) ━━━"
RBF_MD5=$(ssh_read 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' | awk '{print $1}')
echo "  Resident RBF md5: $RBF_MD5"
if [ -n "$EXPECTED_RBF_MD5" ]; then
    echo "  Expected RBF md5: $EXPECTED_RBF_MD5"
    if [ "$RBF_MD5" != "$EXPECTED_RBF_MD5" ]; then
        echo "  UNSCORED: resident RBF does not match the expected bitstream"
        unscored_exit "rbf-md5-mismatch"
    fi
    RBF_VERIFIED=1
else
    echo "  Expected RBF md5: <unset>"
    echo "  ⚠ RBF identity is recorded but not asserted; valid human answers"
    echo "    will be UNSCORED rather than PASS/FAIL."
fi
echo "  Capture time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
echo ""

# ─── PRE-FLIGHT (automated) ──────────────────────────────────────────────────
echo "━━━ PRE-FLIGHT CHECKS (automated) ━━━"

# Daemon alive?
DAEMON_PID=$(ssh_read 'pidof misterplexd 2>/dev/null || echo DEAD')
if [ "$DAEMON_PID" = "DEAD" ]; then
    echo "  UNSCORED: daemon not running"
    unscored_exit "daemon-not-running"
fi
echo "  ✓ Daemon running (PID $DAEMON_PID)"

# Mailbox state
PLXS_MAGIC=$(devmem_read $((0x3007F100)))
PLXF_MAGIC=$(devmem_read $((0x3007F118)))
PLXD_MAGIC=$(devmem_read $((0x3007F128)))
echo "  PLXS magic: $PLXS_MAGIC (expect 0x504C5853)"
echo "  PLXF magic: $PLXF_MAGIC (expect 0x504C5846)"
echo "  PLXD magic: $PLXD_MAGIC (expect 0x504C5844)"

if [ "$PLXS_MAGIC" = "0x00000000" ]; then
    echo "  UNSCORED: FPGA mailboxes are zero — core not running"
    unscored_exit "mailboxes-zero"
fi
echo ""

# ─── START PLAYBACK (automated) ──────────────────────────────────────────────
echo "━━━ STARTING PLAYBACK (automated) ━━━"
if [ -z "$TOKEN" ]; then
    echo "  UNSCORED: missing PLEX_TOKEN/MISTERPLEX_TOKEN; not starting playback"
    exit 0
fi
if ! $SSH "curl -s 'http://127.0.0.1:3005/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F9&offset=0&address=192.168.1.41&port=32400&protocol=http&token=$TOKEN&commandID=99'" >/dev/null 2>&1; then
    echo "  UNSCORED: playback start command failed"
    unscored_exit "playback-start-failed"
fi
echo "  Playback started (ratingKey=9, 1080p→480p transcode)"
echo "  Waiting 5 seconds for frames to flow..."
sleep 5

if ! derive_ddr_layout_from_plxk; then
    echo "  UNSCORED: could not derive DDR layout from PLXK doorbell magic"
    unscored_exit "ddr-layout-not-derived"
fi
DDR_BANK0_HEX=$(hex_addr "$DDR_BANK0")
DDR_BANK1_HEX=$(hex_addr "$DDR_BANK1")
DDR_DOORBELL_HEX=$(hex_addr "$DDR_DOORBELL")
DDR_DOORBELL_DATA=$((DDR_DOORBELL + 4))
DDR_DOORBELL_DATA_HEX=$(hex_addr "$DDR_DOORBELL_DATA")
echo "  Derived DDR layout: stride=$(hex_addr "$DDR_STRIDE") bank0=$DDR_BANK0_HEX bank1=$DDR_BANK1_HEX doorbell=$DDR_DOORBELL_HEX"

# ─── TELEMETRY UNDER LOAD (automated) ────────────────────────────────────────
echo ""
echo "━━━ TELEMETRY UNDER LOAD (automated) ━━━"

# Two PLXD reads 2 seconds apart
PLXD_T0=$(devmem_read $((0x3007F12C)))
PLXK_T0=$(devmem_read "$DDR_DOORBELL_DATA")
sleep 2
PLXD_T1=$(devmem_read $((0x3007F12C)))
PLXK_T1=$(devmem_read "$DDR_DOORBELL_DATA")

echo "  PLXD data t=0: $PLXD_T0"
echo "  PLXD data t=2: $PLXD_T1"
echo "  PLXK data t=0 ($DDR_DOORBELL_DATA_HEX): $PLXK_T0"
echo "  PLXK data t=2 ($DDR_DOORBELL_DATA_HEX): $PLXK_T1"

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
BANK0_W0=$(devmem_read "$DDR_BANK0")
BANK0_W1=$(devmem_read $((DDR_BANK0 + 4)))
BANK1_W0=$(devmem_read "$DDR_BANK1")
BANK1_W1=$(devmem_read $((DDR_BANK1 + 4)))
echo "  Bank 0 $DDR_BANK0_HEX [0:7]: $BANK0_W0 $BANK0_W1"
echo "  Bank 1 $DDR_BANK1_HEX [0:7]: $BANK1_W0 $BANK1_W1"

if [ "$BANK0_W0" = "$BANK1_W0" ] && [ "$BANK0_W0" = "0x2D2D2D2D" ]; then
    echo "  ⚠ Both banks contain idle-painter gray (0x2D). No video content visible."
elif [ "$BANK0_W0" != "$BANK1_W0" ]; then
    echo "  ✓ Banks differ — double-buffering may be active."
fi
echo ""

# Grab last stats line from daemon
STATS=$(ssh_read 'grep "pfps=" /media/fat/misterplex/misterplexd.log | tail -1')
echo "  Last stats: $STATS"
echo ""
echo "TELEMETRY_RAW rbf=$RBF_MD5 expected_rbf=${EXPECTED_RBF_MD5:-unset} rbf_verified=$RBF_VERIFIED stride=$(hex_addr "$DDR_STRIDE") bank0=$DDR_BANK0_HEX bank1=$DDR_BANK1_HEX doorbell=$DDR_DOORBELL_HEX plxd_t0=$PLXD_T0 plxd_t1=$PLXD_T1 plxk_t0=$PLXK_T0 plxk_t1=$PLXK_T1 bank0_words=$BANK0_W0,$BANK0_W1 bank1_words=$BANK1_W0,$BANK1_W1 stats=\"$STATS\""
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

# Optional non-interactive scoring for the operator who re-runs this script
# after collecting the human card. Missing or contradictory answers are UNSCORED,
# never PASS.
score_human_answers() {
    local q1="${Q1:-}" q2="${Q2:-}" q3="${Q3:-}" q4="${Q4:-}" q5="${Q5:-}"
    local missing=0
    echo "HUMAN_ANSWERS Q1=${q1:-_} Q2=${q2:-_} Q3=${q3:-_} Q4=${q4:-_} Q5=${q5:-_}"
    echo "HUMAN_TELEMETRY rbf=$RBF_MD5 expected_rbf=${EXPECTED_RBF_MD5:-unset} rbf_verified=$RBF_VERIFIED plxd_t0=$PLXD_T0 plxd_t1=$PLXD_T1 plxk_t0=$PLXK_T0 plxk_t1=$PLXK_T1 bank0=$BANK0_W0,$BANK0_W1 bank1=$BANK1_W0,$BANK1_W1 stride=$(hex_addr "$DDR_STRIDE")"
    for q in q1 q2 q3 q4 q5; do
        [ -n "${!q}" ] || missing=1
    done
    if [ "$missing" = "1" ]; then
        echo "HUMAN_RESULT=UNSCORED reason=missing-answer"
        return 0
    fi
    case "$q1" in A|B|C|D) ;; *) echo "HUMAN_RESULT=UNSCORED reason=invalid-Q1"; return 0 ;; esac
    case "$q2" in A|B|C|D) ;; *) echo "HUMAN_RESULT=UNSCORED reason=invalid-Q2"; return 0 ;; esac
    case "$q3" in A|B|C|D|E) ;; *) echo "HUMAN_RESULT=UNSCORED reason=invalid-Q3"; return 0 ;; esac
    case "$q4" in A|B|C|D) ;; *) echo "HUMAN_RESULT=UNSCORED reason=invalid-Q4"; return 0 ;; esac
    case "$q5" in A|B|C|D) ;; *) echo "HUMAN_RESULT=UNSCORED reason=invalid-Q5"; return 0 ;; esac
    if [ "$RBF_VERIFIED" != "1" ]; then
        echo "HUMAN_RESULT=UNSCORED reason=rbf-provenance-unverified"
        return 0
    fi

    if [ "$q1" = "A" ] && [ "$q2" = "A" ] && [ "$q3" = "A" ] &&
       [ "$q4" = "A" ] && { [ "$q5" = "A" ] || [ "$q5" = "B" ]; }; then
        echo "HUMAN_RESULT=PASS scope=display-path-only"
        return 0
    fi
    if [ "$q1" = "B" ] && [ "$q3" = "E" ]; then
        echo "HUMAN_RESULT=FAIL reason=frozen-idle-painter"
        return 0
    fi
    if [ "$q1" = "A" ] && { [ "$q2" = "B" ] || [ "$q2" = "C" ]; }; then
        echo "HUMAN_RESULT=FAIL reason=bank-race"
        return 0
    fi
    if [ "$q3" = "B" ] || [ "$q3" = "C" ]; then
        echo "HUMAN_RESULT=FAIL reason=color-channel-or-yuv-error"
        return 0
    fi
    if { [ "$q1" = "C" ] || [ "$q1" = "D" ]; } &&
       { [ "$q2" != "A" ] || [ "$q3" != "A" ] || [ "$q4" != "A" ]; }; then
        echo "HUMAN_RESULT=UNSCORED reason=not-product-picture"
        return 0
    fi
    echo "HUMAN_RESULT=UNSCORED reason=inconsistent-or-unclassified"
}

score_human_answers

# ─── STOP PLAYBACK after 60s (cleanup) ───────────────────────────────────────
echo "(Playback will auto-stop at content end. To stop early: curl http://$HOST:3005/player/playback/stop)"
