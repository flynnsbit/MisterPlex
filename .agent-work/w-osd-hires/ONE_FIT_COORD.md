# ONE-fit coordination — plex_chrome + PRODUCT_NO_STUB (+ w-geom)

**Hold:** Quartus exclusive ON — do not request fit from w-osd-hires.  
**Tip chrome:** see `git rev-parse --short HEAD` on `w-osd-hires`.

## Cargo (single RBF)

| Order | Lane | Change |
|------:|------|--------|
| 1 | w-fit-1 | `PRODUCT_NO_STUB=1` in QSF (uncomment); `stream_path` else `stub_busy=0`; **no telem_flags shorten** |
| 2 | w-osd-hires | Add `rtl/plex_chrome.sv` to `files.qip`; wire in `sys_top.v` after shadowmask before `hdmi_osd`; expose `chrome_hw` |
| 3 | w-geom | content window / fabric scaler if ready same slot |

## Baseline (BINDING — parent locked)

Deployed **`8fdf440f`** = `w-fit-integ/.../remote_out/fit-t7b-prog480/` only.  
**ALM 23585 · M10K 465 · DSP 44** · `pll_hdmi` slack **+0.669 ns**  
`output_files` / `2890baac` = **BANNED**

Post-stub intent: **ALM ~14368 · M10K ~197 · free M10K ~356**  
Chrome Δ: **M10K +12±4 (cap24) · ALM +2.5k±1k · DSP 0 · HDMI slack stay >0 (target ≥+0.20 ns)**  
Net after both: **ALM ~16–18k · M10K ~209–221**

**telem_flags:** gate `stub_busy` bit — **tie to 0**, never delete/shift (`Plex.sv` MSB pack + `fpga_spi.cpp` masks).

**PRESENT_PROFILE=1:** overlay wall/CPU **FLAT or down** when plane=1 (not up).

## Freeze before slot

```bash
make "$PWD/build/test_plex_chrome_sim" && ./build/test_plex_chrome_sim; echo true rc=$?
# expect 0; RED embedded bank-stretch; FREEZE bank 624x480 scale2
python3 tests/unit/test_unit_rollcall.py; echo true rc=$?
```

## Glass after deploy

`docs/plex-chrome-glass-criterion.md` — 1080p `#` bbox 32×32 PASS vs bank ~49×36 FAIL.
