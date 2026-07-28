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

if ! "${SSH[@]}" 'pidof misterplexd >/dev/null' 2>/dev/null; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=daemon-not-running-or-host-unreachable host=$HOST"
    exit "$RC_UNSCORED"
fi

OSD_CONTROL="$("${SSH[@]}" \
    "awk -F= '\$1==\"OSD_CONTROL\"{v=\$2} END{print (v==\"\"?\"unset\":v)}' \
     /media/fat/misterplex/misterplex.conf" 2>/dev/null | tr -d ' \r')"
echo "CONF OSD_CONTROL=$OSD_CONTROL"

BIN=/media/fat/misterplex/bin
LOGMARK="screensaver-gate-$$"

"${SSH[@]}" "printf '%s\n' 'MARK $LOGMARK' >>/media/fat/misterplex/misterplexd.log" >/dev/null 2>&1

# Assert Screensaver (status[15:14]=10) in the background at the capped rate,
# then grade frames while it holds.
"${SSH[@]}" "nohup sh -c 'i=0; while [ \$i -lt $HOLD_WRITES ]; do \
$BIN/set_status --bit 15 1 --bit 14 0 >/dev/null 2>&1; \
i=\$((i+1)); sleep $HOLD_INTERVAL; done' >/dev/null 2>&1 &" >/dev/null 2>&1
HOLD_RC=$?
if [ "$HOLD_RC" -ne 0 ]; then
    echo "SCREENSAVER_RESULT=UNSCORED reason=could-not-assert-selection rc=$HOLD_RC"
    exit "$RC_UNSCORED"
fi
sleep 2

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
    "sed -n '/MARK $LOGMARK/,\$p' /media/fat/misterplex/misterplexd.log | \
     grep -E 'OSD word|idle screen painted' | tail -8" 2>/dev/null)"
echo "DAEMON_LOG_AFTER_SELECTION:"
printf '%s\n' "${DAEMON_LOG:-  (nothing — the daemon did not react to the OSD word)}"

# Put the selection back where we found it. Idle screen is a user setting.
"${SSH[@]}" "$BIN/set_status --bit 15 0 --bit 14 1 >/dev/null 2>&1" >/dev/null 2>&1

MOTION_LOG="$OUTDIR/motion.log"
"$MOTION" "${CAPS[@]}" --expect moving --json "$OUTDIR/motion.json" \
    >"$MOTION_LOG" 2>&1
MOTION_RC=$?
grep -E '^IDLE_MOTION' "$MOTION_LOG" || cat "$MOTION_LOG"

if ! printf '%s' "$DAEMON_LOG" | grep -q 'idle screen painted (mode=2)'; then
    echo "The daemon never painted idle mode 2 after the OSD word selected"
    echo "Screensaver. With OSD_CONTROL=$OSD_CONTROL the OSD poll thread is"
    echo "the first thing to check: startOsdPoll() returns immediately when it"
    echo "is 0, so no menu selection is ever applied."
    echo "SCREENSAVER_RESULT=FAIL reason=daemon-did-not-apply-selection osd_control=$OSD_CONTROL"
    exit "$RC_FAIL"
fi

if [ "$MOTION_RC" -eq 0 ]; then
    echo "SCREENSAVER_RESULT=PASS reason=daemon-applied-and-picture-animates"
    exit 0
fi
echo "SCREENSAVER_RESULT=FAIL reason=selection-applied-but-picture-did-not-move"
exit "$RC_FAIL"
