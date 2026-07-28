#!/usr/bin/env bash
# Prove the OSD "Idle screen" selector actually reaches the screen.
#
# The user's report was "the screensaver still dont work". The daemon gates its
# entire OSD poll thread on OSD_CONTROL: with OSD_CONTROL=0, MediaPlayer::
# startOsdPoll() returns before starting, so the OSD word is never read and no
# menu selection is ever applied. Nothing logs an error, so from the screen the
# symptom is indistinguishable from a broken screensaver renderer.
#
# This card selects Screensaver through the core's status word and then judges
# real pixels. It does NOT judge frame difference: the resident core re-damages
# a ragged prefix of every scanline each frame, so consecutive frames always
# differ by ~17% whether or not anything is animating. scripts/idle_motion_probe.py
# tracks the bright-content centroid instead, which is still while the picture
# is still.
#
# Thrash budget: MiSTer's Main owns the OSD word and restores its shadow within
# about a second, so the selection has to be re-asserted while capturing. Each
# assertion is a UIO/SPI write contending with Main. A previous run of this
# experiment at 80 writes / 0.3s wedged the device hard enough to need a power
# cycle, so the rate and the total are capped here and the card refuses to
# exceed them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
HDMI_DEV="${HDMI_DEV:-/dev/video0}"
OUTDIR="${SCREENSAVER_OUT:-$ROOT/build/screensaver_gate}"
CLASSIFY="$ROOT/scripts/hdmi_capture_classify.py"
MOTION="$ROOT/scripts/idle_motion_probe.py"
FRAMES="${SCREENSAVER_FRAMES:-4}"
# Hard caps. Raising these is how the lab lost a device once already.
HOLD_WRITES="${SCREENSAVER_HOLD_WRITES:-24}"
HOLD_INTERVAL="${SCREENSAVER_HOLD_INTERVAL:-0.5}"
MAX_HOLD_WRITES=32
MIN_HOLD_INTERVAL_MS=400
RC_FAIL=1
RC_UNSCORED=77

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR
     -o ConnectTimeout=10 "$USER@$HOST")

echo "Scope: drives the core's Idle screen selection to Screensaver and grades whether the picture actually animates, using bright-centroid travel rather than frame difference. It proves the OSD word reaches misterplexd and that the screensaver renderer moves; it does NOT prove the OSD menu navigation works from a real keyboard, does not check the animation's appearance, does not fix the separate per-scanline presentation damage, and restores the OSD selection it changed."

if [ "$HOLD_WRITES" -gt "$MAX_HOLD_WRITES" ]; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=hold-writes-over-cap got=$HOLD_WRITES cap=$MAX_HOLD_WRITES"
    exit "$RC_UNSCORED"
fi
HOLD_MS="$(python3 -c "print(int(float('$HOLD_INTERVAL')*1000))" 2>/dev/null || echo 0)"
if [ "$HOLD_MS" -lt "$MIN_HOLD_INTERVAL_MS" ]; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=hold-interval-too-fast got_ms=$HOLD_MS min_ms=$MIN_HOLD_INTERVAL_MS"
    exit "$RC_UNSCORED"
fi
for tool in "$CLASSIFY" "$MOTION"; do
    [ -f "$tool" ] || { echo "SCREENSAVER_RESULT=UNSCORED reason=missing-tool path=$tool"; exit "$RC_UNSCORED"; }
done
command -v sshpass >/dev/null 2>&1 || {
    echo "SCREENSAVER_RESULT=UNSCORED reason=no-sshpass"; exit "$RC_UNSCORED"; }

mkdir -p "$OUTDIR"

# Derive the PLXS window from the shared layout header. Hardcoding 0x3007F1xx
# here would read a stale window that answers with valid magics and never
# changes, which is exactly the trap documented in mailbox_abi_spec.hpp.
LAYOUT="${DDR_FRAME_LAYOUT_HPP:-$ROOT/host/libmisterplex/ddr_frame_layout.hpp}"
DOORBELL="$(python3 - "$LAYOUT" <<'LAYOUTPY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'\bkPlex480pYuv420pDoorbellPhys\s*=\s*(0x[0-9A-Fa-f]+|\d+)', text)
if not m:
    raise SystemExit(1)
print(int(m.group(1), 0))
LAYOUTPY
)"
if [ -z "$DOORBELL" ]; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=layout-parse-failed layout=$LAYOUT"
    exit "$RC_UNSCORED"
fi
printf 'Derived PLXS: 0x%08X\n' $((DOORBELL + 0x100))

if ! "${SSH[@]}" 'pidof misterplexd >/dev/null' 2>/dev/null; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=daemon-not-running-or-host-unreachable host=$HOST"
    exit "$RC_UNSCORED"
fi

OSD_CONTROL="$("${SSH[@]}" \
    "awk -F= '\$1==\"OSD_CONTROL\"{v=\$2} END{print (v==\"\"?\"unset\":v)}' \
     /media/fat/misterplex/misterplex.conf" 2>/dev/null | tr -d ' \r')"
echo "CONF OSD_CONTROL=$OSD_CONTROL"

BIN=/media/fat/misterplex/bin

# Resolve the log the daemon is ACTUALLY writing, from its own stdout fd, rather
# than assuming a path. A hardcoded path that the daemon is not writing to makes
# this card report "the daemon did not react to the OSD word" and point the
# reader at startOsdPoll(), when the truth is that the card was reading an
# unrelated file. That happened: the daemon was started with its output
# redirected elsewhere, every OSD word was applied correctly, and the card
# blamed the OSD poll thread. A wrong diagnosis is worse than no diagnosis.
DAEMON_LOG_PATH="$("${SSH[@]}" \
    'p=$(pidof misterplexd | awk "{print \$1}"); readlink -f /proc/$p/fd/1 2>/dev/null' \
    2>/dev/null | tr -d ' \r')"
case "$DAEMON_LOG_PATH" in
    /*) ;;
    *) DAEMON_LOG_PATH="" ;;
esac
if [ -z "$DAEMON_LOG_PATH" ] || \
   ! "${SSH[@]}" "[ -f '$DAEMON_LOG_PATH' ] && [ -r '$DAEMON_LOG_PATH' ]" 2>/dev/null; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=daemon-log-unresolvable got='${DAEMON_LOG_PATH:-none}'"
    echo "  This card grades the daemon's reaction to the OSD word from its log."
    echo "  Without the log it cannot tell 'never applied' from 'not observed',"
    echo "  and those have opposite fixes. Refusing to guess."
    exit "$RC_UNSCORED"
fi
echo "DAEMON_LOG_PATH=$DAEMON_LOG_PATH"

# Read-only byte offset instead of writing a marker line into the log. The
# daemon holds this file open with its own write offset, so a marker appended by
# another process is not reliably followed by the daemon's later writes: the
# daemon keeps writing at ITS offset and the marker ends up stranded at the end.
# That made the card read an empty window and report the daemon as unresponsive
# while it was in fact applying every OSD word. stat the size first, then read
# from there.
LOG_OFFSET="$("${SSH[@]}" "stat -c %s '$DAEMON_LOG_PATH' 2>/dev/null" 2>/dev/null | tr -d ' \r')"
case "$LOG_OFFSET" in
    ''|*[!0-9]*)
        echo "SCREENSAVER_RESULT=UNSCORED reason=daemon-log-size-unreadable path=$DAEMON_LOG_PATH"
        exit "$RC_UNSCORED" ;;
esac

# Assert Screensaver (status[15:14]=10) in the background at the capped rate,
# then grade frames while it holds.
#
# setsid, not a bare "&". A backgrounded child of an ssh command is torn down
# when the session closes, so the previous form here started nothing and still
# reported success: ssh exited 0, the loop was already dead, and the card went
# on to grade a screen nobody had asked to change. ssh's exit status describes
# ssh, not the work.
HOLD_STAMP="$OUTDIR/hold.pid"
"${SSH[@]}" "setsid sh -c 'i=0; while [ \$i -lt $HOLD_WRITES ]; do \
$BIN/set_status --bit 15 1 --bit 14 0 >/dev/null 2>&1; \
i=\$((i+1)); sleep $HOLD_INTERVAL; done' </dev/null >/dev/null 2>&1 & echo \$!" \
    >"$HOLD_STAMP" 2>/dev/null
sleep 2

# Do not take "the loop was launched" on trust either. The only evidence that
# the selection reached the fabric is the OSD word itself, read back out of the
# PLXS mailbox: bits [15:14] must be 0b10. Anything else and the captures cannot
# be about the screensaver.
OSD_SEEN=""
for _ in 1 2 3 4 5 6; do
    W="$("${SSH[@]}" "devmem $(printf '0x%08X' $((DOORBELL + 0x104))) 32" 2>/dev/null | tr -d ' \r')"
    case "$W" in
        0x*) SEL=$(( ( $(printf '%d' "$W") >> 14 ) & 3 ))
             if [ "$SEL" -eq 2 ]; then OSD_SEEN="$W"; break; fi ;;
    esac
    sleep 0.5
done
if [ -z "$OSD_SEEN" ]; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=selection-never-reached-osd-word last=${W:-none}"
    echo "  The hold loop never drove status[15:14] to 0b10 where the fabric"
    echo "  publishes it, so nothing was selected and the frames below would be"
    echo "  of whatever was already on screen."
    exit "$RC_UNSCORED"
fi
echo "OSD_WORD_OBSERVED=$OSD_SEEN (status[15:14]=0b10 Screensaver)"

CAPS=()
for i in $(seq 1 "$FRAMES"); do
    out="$OUTDIR/frame_$i.png"
    "$CLASSIFY" --device "$HDMI_DEV" --out "$out" --expect any \
        >"$OUTDIR/classify_$i.log" 2>&1
    if [ ! -f "$out" ]; then
        echo "SCREENSAVER_RESULT=UNSCORED reason=capture-unavailable dev=$HDMI_DEV frame=$i"
        exit "$RC_UNSCORED"
    fi
    CAPS+=("$out")
done

DAEMON_LOG="$("${SSH[@]}" \
    "tail -c +$((LOG_OFFSET + 1)) '$DAEMON_LOG_PATH' | \
     grep -E 'OSD word|idle screen painted' | tail -12" 2>/dev/null)"
echo "DAEMON_LOG_AFTER_SELECTION (from byte $LOG_OFFSET):"
printf '%s\n' "${DAEMON_LOG:-  (no daemon output at all in the observed window)}"

# Put the selection back where we found it. Idle screen is a user setting.
"${SSH[@]}" "$BIN/set_status --bit 15 0 --bit 14 1 >/dev/null 2>&1" >/dev/null 2>&1

MOTION_LOG="$OUTDIR/motion.log"
"$MOTION" "${CAPS[@]}" --expect moving --json "$OUTDIR/motion.json" \
    >"$MOTION_LOG" 2>&1
MOTION_RC=$?
grep -E '^IDLE_MOTION' "$MOTION_LOG" || cat "$MOTION_LOG"

# Evidence order matters here. The OSD word read back out of the fabric and
# the pixels on the wire are both measurements; the daemon log is only
# corroboration, and it is a lossy one because the daemon logs on CHANGE. If
# the selection was already applied before the observation window opened,
# the log is empty while the screensaver is plainly running. An earlier
# version of this card let that empty log override a measured 30.8px of
# centroid travel and returned UNSCORED. A silent log cannot unmake a moving
# picture, so motion is decided first and the log is used only to explain a
# picture that did NOT move.
if [ "$MOTION_RC" -eq 0 ]; then
    echo "SCREENSAVER_RESULT=PASS reason=osd-word-observed-and-picture-animates osd_control=$OSD_CONTROL"
    exit 0
fi

# From here the picture was static. Now the log earns its keep: the fixes for
# 'never selected', 'selected but Main took it back' and 'selected and the
# renderer is dead' are three different fixes with one symptom.
if [ -z "$DAEMON_LOG" ]; then
    echo "The picture did not move, and the daemon logged nothing in the window,"
    echo "so this card cannot tell a dead renderer from a selection that was"
    echo "already in effect before the window opened. The daemon logs on change."
    echo "SCREENSAVER_RESULT=UNSCORED reason=static-picture-and-silent-log path=$DAEMON_LOG_PATH"
    exit "$RC_UNSCORED"
fi

if ! printf '%s' "$DAEMON_LOG" | grep -q 'idle screen painted (mode=2)'; then
    echo "The daemon logged activity but never painted idle mode 2 after the OSD"
    echo "word selected Screensaver. With OSD_CONTROL=$OSD_CONTROL the OSD poll"
    echo "thread is the first thing to check: startOsdPoll() returns immediately"
    echo "when it is 0, so no menu selection is ever applied."
    echo "SCREENSAVER_RESULT=FAIL reason=daemon-did-not-apply-selection osd_control=$OSD_CONTROL"
    exit "$RC_FAIL"
fi

# Main owns the OSD status word and restores its own shadow within about a
# second, so an injected selection is transient by construction. When the log
# shows the daemon flipping between mode=2 (our injection) and mode=1 (Main's
# restore), the captured frames are a mixture of both idle screens and a
# STATIC verdict says nothing about the renderer. That is a limit of injecting
# the word from outside, not a product defect, so it is UNSCORED. Calling it
# FAIL would send someone to fix a renderer that works.
if printf '%s' "$DAEMON_LOG" | grep -q 'idle screen painted (mode=1)'; then
    echo "The daemon applied Screensaver (mode=2) but the log also shows it"
    echo "painting mode=1 in the same window: Main restored its own OSD shadow"
    echo "while frames were being captured, so the frames are a mixture of both"
    echo "idle screens and the motion verdict is not attributable."
    echo "Drive the selection through Main's real OSD menu (tests/hw/osd_keys.py)"
    echo "to make it stick, rather than raising the injection rate — that is what"
    echo "wedged the device once already."
    echo "SCREENSAVER_RESULT=UNSCORED reason=selection-not-held-against-main osd_control=$OSD_CONTROL"
    exit "$RC_UNSCORED"
fi

echo "SCREENSAVER_RESULT=FAIL reason=selection-applied-but-picture-did-not-move"
exit "$RC_FAIL"
