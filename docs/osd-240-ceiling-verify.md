# T1–T4: Overlay path vs 240-line ceiling (source verify)

**Worker:** w-osd-hires · tip at commit time  
**Verdict:** **(b)** — user-visible fix **requires** post-ascal RTL plane. ARM-only paint at “output size” into F1 is **cosmetic on glass**.  
**Coordinate with:** `w-fit-integ` `docs/chrome-post-scale-plane-design.md` (not a parallel architecture).

Parent measurement (period-3 on 1280×720 capture, contrast ~11) is **consistent with source**. Minor geometry nit below does **not** overturn the 240 finding.

---

## T1 — Overlay pixel path (every hop, quoted)

### Product present mode

Daemon product path is `PRESENT=fpga` DDR F1 (not a separate OSD framebuffer for player chrome).

### Idle / STOPPED

```text
media_player.cpp paintIdle():
  g = plex480pDdrFrameGeometry()     // coded 624×480  [ddr_frame_layout.hpp:192-204]
  cw,ch = g.coded_width/height
  renderIdleRgb24(rgb, cw, ch)
  overlay_.renderRgb24(rgb, cw, ch)  // chrome INTO bank-sized buffer
  RGB→I420 encode
  publishDdrFrame(..., g, Yuv420p)   // → HPS DDR @ frame store base
```

Log evidence (live parent): `media: idle overlay canvas=624x480 ...`

### Pause (sticky)

```text
publishPausedOverlayFrame():
  g = plex480pDdrFrameGeometry()     // same 624×480
  yuv = latch or studio black
  overlay_.renderYuv420p(yuv, cw, ch)
  publishDdrFrame(..., "pause overlay DDR")
```

### Play / timeline chrome

```text
rawW = ddrGeometry.coded_width.get();   // media_player.cpp ~2391
rawH = ddrGeometry.coded_height.get();
// ...
presentCleanFrame:
  renderOverlay(cleanFrame)             // renderYuv420p(data, rawW, rawH) for product
  publishDdrFrame(..., "playback DDR")  // when useDdrF1_ && !reconOwnsF1 path
```

`ddrGeometry` for FPGA present is forced to product bank via
`ddrFrameGeometryForFpgaPresent` / `plex480p` — **not** HDMI WxH
(`ddr_frame_layout.hpp:226-238` comments: silicon constant).

### FPGA hop (no bypass)

```text
publishDdrFrame → FpgaSpi → DDR phys (ddr_frame_store PHYS_BASE 0x3000_0000)
present_core.sv:
  ddr_frame_store fstore (.rd_x(store_x), .rd_y(store_y), ...)  // ~239-260
  store_y from STORE_Y_SCALE path below
  fr,fg,fb → core video out
sys_top.v:
  ascal → hdmi_data → shadowmask → osd hdmi_osd → HDMI_TX   // ~714-1205
```

Framework `osd` (`osd.v`) is **F12 menu only** (256×64 class buffer). **Player chrome does not enter `osd`.** There is **no** alternate ARM→HDMI chrome plane in product RTL today.

### Does overlay bypass `store_y`?

**No.** Every product chrome path above ends in `publishDdrFrame` → `ddr_frame_store` → `rd_y = store_y`.  
Parent’s 240 analysis **applies to overlay and video equally**.

Optional `fb_.blitYuv420p` is parallel Linux fb0; product glass for `PRESENT=fpga` is the DDR path. fb0 is not the HDMI ascal path parent is measuring.

---

## T1b — Verify parent’s `STORE_Y` math (with one correction)

Quoted product macros:

```text
Plex.qsf:83-84
  FRAME_W=640
  FRAME_H=480
```

Parent wrote `FRAME_W=624`. **Coded bank** is 624 (`ddr_frame_layout_params.svh:5` `DDR_FRAME_CODED_WIDTH=624`); **present_core parameter** `FRAME_W` is **640**.  
Vertical math uses `FRAME_H`, not coded width — **240 finding unchanged**.

```text
present_core.sv:161-164,170-171,196-200
  H_DE = 529
  V_STORE = 240
  STORE_Y_SCALE = (FRAME_H * 65536) / 240
               = (480 * 65536) / 240 = 131072 = 2.0 in 16.16 exactly
  py = scandouble ? (vc >> 1) : vc
  in_content = (hc < H_DE) && (py < V_STORE) && ...
  store_y_clamped = past_last_row ? 239 : py
  store_y_comb = (store_y_clamped * STORE_Y_SCALE) >> 16
              = py * 2   for py in 0..239
```

Unique `store_y` addresses fetched under normal DE: **0,2,4,…,478** → **240 distinct rows** of the 480-line bank.  
Odd authored rows never read. Scandouble still folds to `py < 240`.

Horizontal: `H_DE=529` samples across `FRAME_W` via `STORE_X_SCALE`; non-integer map to HDMI is consistent with parent “no horizontal period”.

**Parent period-3 on 1280×720 capture:** 720/240 = 3 → period-3 fundamental is the **expected** signature of 240 source lines scaled to 720. **Not refuted.**

---

## T2 — Can the daemon know OUTPUT resolution?

| Source | In tree today? | Used for chrome authoring? |
|--------|----------------|----------------------------|
| `/media/fat/MiSTer.ini` `[Plex] video_mode=` | **Readable** — `host/libmisterplex/mister_video_mode.hpp` (`f18223ab`) maps index 12→1920×1440 | **Log only** (`output=` tag); **not** paint size |
| `/dev/fb0` `FBIOGET_VSCREENINFO` | `fb_present.cpp` can read xres/yres | **Not** product F1 size |
| Live scaler `WIDTH`/`HEIGHT` in `sys_top.v` | HPS programs ascal; **not** wired to misterplexd SPI status | **No** |
| DECODE / conf `624x480` | Yes | **Yes — this is `canvas=`** |

**Finding:** output raster is **knowable** (ini) and now **logged** as `output=WxH mode=N plane=0`.  
Knowing it does **not** let ARM place more than 240 distinct vertical chrome samples on the F1 path.

---

## T3 — Honest classification

| Claim | Result |
|-------|--------|
| (a) Pure ARM-side fix, visible on glass | **FALSE** for user sharpness requirement |
| (b) Requires RTL post-ascal plane; ARM-only is cosmetic | **TRUE** |

Painting 1920×1080 into DDR F1 would still be read through `store_y = py*2` into a 529×240 DE, then ascal — host tests can go green; glass stays period-3 mush (**fourth instance** of that class if shipped).

**Required architecture (align w-fit-1, do not fork):**

- Tap: **after ascal**, before/with `osd` (`sys_top.v` ~1170–1205) — never inside `present_core` pre-ascal.
- Storage: full BRAM plane **fails** (4320 M10K); banded DDR N≤8 or glyph-list **fits** 88 free M10K — see w-fit `chrome-post-scale-plane-design.md` F2.
- ARM role after RTL: build chrome at **output W×H** (ini/status), write chrome DDR or display list; **stop** compositing transport into F1 when `plane=1`.

ARM still useful **now:** black-rect, sticky pause, dual log, layout metrics for future plane — **not** the resolution fix.

---

## T4 — One falsifiable single-frame test

**Criterion (parent’s):**  
In **one** HDMI frame with pause chrome up:

1. **Video ROI** (center, away from panel): period-3 row structure **PRESENT** (content still through F1).  
2. **Overlay ROI** (bottom panel / “PAUSED” band): period-3 structure **ABSENT** (or contrast ratio ≪ video).

| Result | Meaning |
|--------|---------|
| Both ROIs period-3 strong | Chrome still on F1 (today / failed ARM-only) |
| Video period-3, overlay flat/sharp | Post-ascal plane working |
| Neither period-3 | Wrong mode / scaled content / bad crop — do not score PASS |

Tool: `tools/score_overlay_vs_video_period3.py`  
Host baseline on archive PAUSED: **both fail native** (overlay still bank path).

```bash
python3 tools/score_overlay_vs_video_period3.py CAPTURE.png; echo "true rc=$?"
python3 tools/score_overlay_vs_video_period3.py --selftest; echo "true rc=$?"
```

---

## Bottom line for parent

Your 240-line measurement is **correct for the overlay path**.  
**I am not pursuing ARM-only output-sized F1 paint as the user fix.**  
Next product step is **w-fit-1 post-ascal plane** + ARM list/band writer; this worker stays on ARM prep + gates until fit is granted.
