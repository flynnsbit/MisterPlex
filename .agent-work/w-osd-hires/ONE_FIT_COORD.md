# ONE-fit coordination — plex_chrome + PRODUCT_NO_STUB (+ w-geom)

**Hold:** Quartus exclusive ON — do not request fit from w-osd-hires.  
**Tip chrome:** see `git rev-parse --short HEAD` on `w-osd-hires`.

## Cargo (single RBF)

| Order | Lane | Change |
|------:|------|--------|
| 1 | w-fit-1 | `PRODUCT_NO_STUB=1` in QSF (uncomment); `stream_path` else `stub_busy=0`; **no telem_flags shorten** |
| 2 | w-osd-hires | Add `rtl/plex_chrome.sv` to `files.qip`; wire in `sys_top.v` after shadowmask before `hdmi_osd`; expose `chrome_hw` |
| 3 | w-geom | content window / fabric scaler if ready same slot |

## Baseline (BINDING until 8fdf settled)

`fit-t7b-prog480` / 8fdf hierarchy: **ALM 23585 · M10K 465 · DSP 44**  
Post-stub intent: **ALM ~14368 · M10K ~197 · free M10K ~356**  
Chrome Δ: **M10K +12±4 (cap24) · ALM +2.5k±1k · DSP 0**

If deployed RBF matches `output_files` (21822/DSP74) instead — **stop and re-prereg**.

## Freeze before slot

```bash
make "$PWD/build/test_plex_chrome_sim" && ./build/test_plex_chrome_sim; echo true rc=$?
# expect 0; RED embedded bank-stretch; FREEZE bank 624x480 scale2
python3 tests/unit/test_unit_rollcall.py; echo true rc=$?
```

## Glass after deploy

`docs/plex-chrome-glass-criterion.md` — 1080p `#` bbox 32×32 PASS vs bank ~49×36 FAIL.
