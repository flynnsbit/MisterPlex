# True480 / 720p24 pointer (2026-08-12)

Canonical case law lives in the product tree, not this dirty `main` checkout:

- Worktree: `/home/shawn/Projects/MisterPlex-wt-480p-lessons`
- Branch: `lessons/true480-720p24` (tracks `origin/480p` @ `a6ba15d`)
- File: `docs/LESSONS.md` L44–L56
- Backlog: `docs/PHASE_BACKLOG.md` P3-TRUE480 / P3-720P24 / **P4-DISPLAY** / **P4-720P-MIX** (TODO; not DONE)

v0.4.1 pair: RBF md5 `07f54d9f8f0eda2fe75d9cc314f6de54`.

720p24 (2026-08-13): lab **`17dd3b56`** unique pfps **15.2–15.47** vs W-meas F=**32.31**. Live exclusive **B** fabric-direct (`slot720p24f`). **Deferred path:** use **both** HPS DDR3 and the SDRAM stick — `PATH_SDRAM_PLUS_DDR.md` (stick is tri-stated today). Soft-skip ≠ PASS.

**Fleet fix (user 2026-08-13):** F12 Display must change the real MiSTer HDMI/VGA raster or the setting is meaningless (`P4-DISPLAY`). 720p Display ≠ content hangs play on True480; 240/240, 240/480, 480/480 play — `P4-720P-MIX`. Card: `DISPLAY_RES_MUST_CHANGE_RASTER.md`.

**Freddo MPEG2 note (L56):** YUV-until-scan is already Plex. Keep I420; RGB only on the beam. The steal is gather (Branch B / no ARM memcpy), resync after a faster blit, scan-order recon writes, and a real idle raster. Card: `FREDDO_YUV_LAST_RGB.md`.

No Plex tokens in this file.
