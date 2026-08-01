#!/usr/bin/env python3
"""Host red-before-green: pause must paint sticky chrome and publish before SIGSTOP.

Test B (silicon): pause left a frozen video frame with no panel. Root causes gated here:
  1) MediaPlayer::pause must call publishPausedOverlayFrame before signalChildren(SIGSTOP).
  2) PlaybackOverlay Paused state must stay visible past kVisibleMs (no auto-wipe).
  3) Pause present loop must not presentCleanFrame when overlay is invisible (wipe).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
OVERLAY = ROOT / "host" / "libmisterplex" / "playback_overlay.hpp"


def fail(msg: str) -> None:
    print(f"FAIL pause_overlay_publish: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    media = MEDIA.read_text()
    ov = OVERLAY.read_text()

    # --- pause() order ---
    m = re.search(
        r"void\s+MediaPlayer::pause\s*\(\s*\)\s*\{(.*?)\n\}",
        media,
        re.S,
    )
    if not m:
        fail("MediaPlayer::pause not found")
    body = m.group(1)
    if "showPlaybackOverlay(PlaybackOverlayState::Paused" not in body:
        fail("pause() must show Paused overlay")
    pub = body.find("publishPausedOverlayFrame")
    stop = body.find("signalChildren(SIGSTOP)")
    if pub < 0:
        fail("pause() must call publishPausedOverlayFrame")
    if stop < 0:
        fail("pause() must SIGSTOP children (product pause)")
    if not (pub < stop):
        fail("publishPausedOverlayFrame must run BEFORE SIGSTOP")

    # --- sticky PAUSED + STOPPED in alphaFor ---
    if "PlaybackOverlayState::Paused" not in ov:
        fail("overlay missing Paused state")
    af = re.search(r"static int alphaFor\(const Snapshot& s, int64_t nowMs\) \{(.*?)\n    \}", ov, re.S)
    if not af:
        fail("alphaFor not found")
    af_body = af.group(1)
    if "PlaybackOverlayState::Paused" not in af_body:
        fail("alphaFor must special-case Paused (sticky) — without it Test B wipes at 3s")
    if "PlaybackOverlayState::Stopped" not in af_body:
        fail("alphaFor must special-case Stopped (sticky) — stop chrome must survive warm-up")
    if "return 255" not in af_body:
        fail("Paused/Stopped branch must return full alpha (255)")
    # Playing still times out via kVisibleMs
    if "age >= kVisibleMs" not in af_body:
        fail("Playing timeout path missing")
    # --- pause loop must not wipe ---
    # Look for comment or structure: only present when overlay visible
    if "do NOT presentCleanFrame" not in media and "do not presentCleanFrame" not in media.lower():
        # structural: paused branch should not call presentCleanFrame unconditionally
        # Find the paused_.load() block in threadMain RGB loop near pauseClockHeld
        if "pauseClockHeld" not in media:
            fail("RGB pause loop marker pauseClockHeld missing")
    # Require overlayNow gate before presentCleanFrame in pause path
    idx = media.find("pauseClockHeld")
    chunk = media[idx : idx + 1200]
    if "presentCleanFrame" in chunk and "overlayNow" not in chunk and "overlay_.visible()" not in chunk:
        fail("pause loop presentCleanFrame must be gated on overlay visibility")

    # --- loud success log (diagnosability) ---
    if 'pause overlay DDR ok' not in media:
        fail('publishPausedOverlayFrame must log success "pause overlay DDR ok"')

    print(
        "test_pause_overlay_publish_static: OK "
        "pause=show+publish before SIGSTOP; "
        "Paused alpha sticky; "
        "no clean wipe when hidden; "
        "success log present"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
