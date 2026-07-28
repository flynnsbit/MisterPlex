# The screensaver works. Three bugs in the card said otherwise.

Branch `w-osd-o5`. Device `192.168.1.183`, RBF md5 `fb4bad849ad2db782a5004ce5a3471ce`,
`OSD_CONTROL=1`, Plex core loaded and scanning out. Measured, not reconstructed.

## Result

`tests/hw/test_osd_screensaver_selects.sh` → **rc=0**

```
OSD_WORD_OBSERVED=0xFDB2A000 (status[15:14]=0b10 Screensaver)
IDLE_MOTION point cx=286.30 cy=385.85
IDLE_MOTION point cx=264.70 cy=377.14
IDLE_MOTION point cx=237.70 cy=382.09
IDLE_MOTION point cx=240.44 cy=385.25
IDLE_MOTION verdict=MOVING travel=49.37 span_x=48.60 span_y=8.71
SCREENSAVER_RESULT=PASS reason=osd-word-observed-and-picture-animates osd_control=1
```

The bright centroid walks left across three frames and turns — a bouncing logo. `frame_1..4.png`
are those exact captures.

## What the card got wrong first

`00_before_fixes_wrong_diagnosis.log` is the same card, same working device, reporting:

```
DAEMON_LOG_AFTER_SELECTION:
  (nothing — the daemon did not react to the OSD word)
SCREENSAVER_RESULT=FAIL reason=daemon-did-not-apply-selection osd_control=1
```

Every part of that sentence was false, and it named `startOsdPoll()` as the place to look. A
confident wrong diagnosis costs more than no diagnosis. Three separate defects produced it:

**1. The hold loop never ran.** The card launched it as a backgrounded child of an `ssh`
command. That is torn down when the session closes. The card then checked `ssh`'s exit
status, got 0, and proceeded — `ssh` succeeded, the work did not. Now the loop is launched
with `setsid`, and launching is no longer treated as evidence: the card reads the OSD word
back out of the `PLXS` mailbox and requires `status[15:14] == 0b10` before it captures
anything. `OSD_WORD_OBSERVED` in the log above is that read.

**2. The log window was established by writing a marker into the daemon's log.** The daemon
holds that file open with its own write offset, so a line appended by another process is not
reliably followed by the daemon's later writes — the marker ends up stranded at the end and
the card reads an empty window. Replaced with a read-only `stat -c %s` byte offset taken
before the selection, read back with `tail -c +N`.

**3. The log path was hardcoded.** The daemon was writing elsewhere, so the card read an
unrelated file and reported the daemon as unresponsive. The path is now resolved from
`/proc/<pid>/fd/1`, and an unresolvable log is `UNSCORED`, never a verdict — "not observed"
and "never applied" have opposite fixes.

## The evidence order, which was also wrong

Even after those three, the card returned `UNSCORED` on a run showing 30.8px of measured
centroid travel, because the daemon log was empty. The daemon logs on *change*: if the
selection was already in effect when the window opened, there is nothing to log while the
screensaver is plainly running.

The OSD word read out of the fabric and the pixels on the wire are measurements. The daemon
log is lossy corroboration. So motion is decided first, and the log is consulted only to
explain a picture that did **not** move — where it usefully separates three causes with one
symptom: never selected, selected but Main took the word back, selected and the renderer is
dead. `tests/unit/test_screensaver_osd_control.sh` case 6c asserts this ordering in the
source, so it cannot be quietly reversed.

## Paired red

The matching red for this green is the `OSD_CONTROL=0` capture set in
`../screensaver_osd_control/red_osd_control_0/`: same Screensaver selection, travel **0.0px**,
`STATIC`. `tests/unit/test_screensaver_osd_control.sh` grades both committed sets every run,
and separately proves a frame-difference gate would have passed the broken one (the broken
captures differ by 11.6% of the left band frame-to-frame purely from the presentation damage).

## What this does not prove

It does not prove the selection can be made from a real keyboard through Main's OSD menu —
the word is injected here, and Main restores its own shadow within about a second, so the
selection is transient by construction. `tests/hw/osd_keys.py` through the real menu is the
open item. It also does not fix, or excuse, the separate per-scanline presentation damage
documented in `../idle_rca_false_pass_menu/`; the screensaver animates *through* that damage.
