# w-osd-hires STATUS — post 2b44d935 silicon P2 MISS

## RCA (quoted host evidence)

1. Title MISTERP + empty band, no ellipsis
   - overlay_font_24x32 glyph('.') had no case - default return space
   - probe: glyph('.') == glyph(' ') and period ink_pixels=0 on 2b44d935
   - Long media titles fitText to MISTERP... with three blank advances
   - Visual = MISTERP + empty band (matches glass). Not advance 52 vs 32.
   - Parent ~32 px/glyph used scale 1920/624; height-fit ~2x gives ~52 = advPx.

2. Elapsed 0:52 vs total 0:30, bar at 100%
   - Bar: min(positionMs, durationMs)/durationMs
   - Elapsed: formatTime(positionMs) unclamped
   - pos=52000 dur=30016 -> elapsed 0:52, total 0:30, bar 100%
   - Timeline poll 30016/30016 is separate (clamped); HUD elapsed was wall overrun.

## Fix
- Period glyph in 24x32, 8x13, 12x16
- Elapsed display clamped to duration (same source as bar)
- test_overlay_layout_fit PIXEL gate: period ink, 10 slots full title,
  long title ellipsis slots ink>0 (RED when period=space)

## PREREG at 624x480 Hires24x32@2
- advPx=52, tw(MISTERPLEX)=518, titleMaxW=566, secondLine=1
- long -> fitted MISTERP... with visible dots
- pos 52000/30016 -> elapsed=total=0:30

## Deploy
- Match kill pattern with trailing wildcard for (deleted) exe
- stage -> md5 -> mv -f -> kill by PID
- md5: see DAEMON_MD5.txt
