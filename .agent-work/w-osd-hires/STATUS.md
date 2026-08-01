# w-osd-hires STATUS

## Tip
See `git rev-parse --short HEAD` on branch `w-osd-hires`.

## User bug #2
**NOT FIXED on glass** until post-ascal `plex_chrome` + parent 1080p score.
ARM bank path paints but stretches — evidence `overlay_lowres_stopped_9ce2c2d1.png`.

## Design / sim (this lane)
- `docs/plex-chrome-plane-rtl-proposal.md` — tap, PLXC, budget
- `docs/plex-chrome-glass-criterion.md` — falsifiable G-CELL / G-RUN
- `rtl/plex_chrome.sv` — fit-ready, **NOT in QSF**
- `test_plex_chrome_sim` — RED bank-stretch rc path; GREEN fabric; FREEZE 624×480

## Budget BINDING
t7b/8fdf: ALM 23585 M10K 465 DSP 44
PRODUCT_NO_STUB: −9217 ALM −268 M10K → ~356 free
Chrome V1: +12±4 M10K cap24, +2.5k±1k ALM, DSP 0
Do not assume output_files 21822/DSP74 until w-fit-1 settles 8fdf.

## ONE-fit
Coordinate w-fit-1 PRODUCT_NO_STUB + this plane (+ w-geom). Quartus hold ON — no fit request.
