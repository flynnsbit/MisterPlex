# w-osd-hires status

## Summary (≤10 lines)
1. Bug #2 still OPEN on glass — bank 624×480 chrome stretched (plane=0).
2. HALF A DONE: ini `[MiSTer]` fallback + honest `source=ini:mister|ini:plex|none`.
3. HALF B gate DONE: RED BAD rc=1, GREEN GOOD rc=0, FIT_INTEG sys_top still RED rc=1.
4. RTL: BOOT_DEMO → list_a[0]; noprune list RAM; product needs non-const list_we.
5. c74c6863 NO-DATA mechanised: list_we=0 + wrong bank; gate encodes both.
6. unit-unlocked true rc=0; test_mister_video_mode true rc=0; chrome_sim true rc=0.
7. Daemon rebuilt; parent deploy for log line only — does NOT fix glass sharpness.
8. No Quartus request. ONE-fit waits w-fit-1 GOOD sys_top wire + telem gate.

## Evidence (direct rc)
- BAD subject: true rc=1
- GOOD subject: true rc=0
- full write-path gate: true rc=0
- w-fit-integ sys_top: true rc=1 (still c74c dead write)
- test_mister_video_mode: true rc=0
- test_plex_chrome_sim: true rc=0
- make unit-unlocked: true rc=0
- make arm-plexd: true rc=0
