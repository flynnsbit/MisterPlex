# w-osd-hires STATUS

## Layout regression fix (post 23b2f8df silicon)

Parent scored 23b2f8df: font win (24x32@2 cell=48x64) + layout REGRESSION
(title "PAUSEDM", duration looked like 0:30). Rolled back to 9ce2c2d1.

### Fix
- `computePanelLayout` grows panel for second-line title when MISTERPLEX cannot
  share the state row at cell 48x64.
- Title fit-to-width with ellipsis; duration right-aligned from measured width.
- Gate: `test_overlay_layout_fit` RED on same-line-only, GREEN on fix.

### PREREG (624x480 bank, Hires24x32@2)
| metric | value |
|---|---|
| tw("PAUSED") | 310 |
| tw("MISTERPLEX") | 518 |
| BOTH same-line | 882 > panelW 594 → secondLine=1 |
| tw("2:14")/("2:18") | 206 each; gap>=0 |
| panel | w=594 h=154 base / h=222 with title |

### DURATION_VERDICT
Geometry fits 2:14/2:18 and 2:14/6:00. Parent "0:30" NOT explained by
total-string overflow on host path (unknown — need device durationMs).

### Host gates (true rc direct)
- test_overlay_layout_fit: PASS rc=0
- test_playback_overlay: OK rc=0 (golden regen)
- test_overlay_post_upscale: OK rc=0
- test_overlay_crispness_mutation: OK rc=0
- test_overlay_source_stroke_hist: PASS rc=0

### Daemon
See DAEMON_MD5.txt — atomic deploy only (stage→md5→mv -f→kill).

### Glass expect after deploy
- Full "MISTERPLEX" on second title line (not PAUSEDM)
- Elapsed + total both fully visible
- Glyphs still large/smooth vs BEFORE 8fdf440f
