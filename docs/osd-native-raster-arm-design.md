# ARM native-raster overlay design (post-`cleanFrame`)

**Worker:** w-osd-hires · coordinates w-fit-1 / w-geom / w-cpu-1  
**No Quartus. No device claims.**

## 0. The line (verified this tip)

Parent cited ~3479/3485 (line drift). **This branch:**

```text
media_player.cpp:3156  renderOverlay(cleanFrame);   // profile path
media_player.cpp:3162  renderOverlay(cleanFrame);   // normal path
// inside presentCleanFrame, BEFORE:
media_player.cpp:3195  publishDdrFrame(frame, "playback DDR", …)
```

`renderOverlay` → `overlay_.renderYuv420p(data, rawW, rawH)` with  
`rawW/H = ddrGeometry.coded_*` (624×480 bank).

**Same class of bug:** `publishPausedOverlayFrame` / `paintIdle` also  
`render*` into bank then `publishDdrFrame`.

**Conclusion (rd-review + parent + this worker):** sharper pixels in `cleanFrame`  
cannot fix the user bug. Chrome must **leave** the pre-publish canvas.

**B3 judder:** CLOSED per parent/rd-review — static PAUSED chrome does not  
judder under latch phase. No longer an open design driver.

**H columns:** do not assume 640 DE; product H_DE=529; clk_sys 20 MHz class  
(parent). Plane geometry uses **HDMI W×H**, not core DE.

---

## 1. Target architecture (ARM half of w-fit plane)

```text
TODAY:
  video → cleanFrame → renderOverlay(cleanFrame) → publishDdrFrame(F1)
                         ↑ USER BUG (529×240 pinhole then ascal)

TARGET (plane=1, same RBF as w-fit chrome):
  video → cleanFrame → publishDdrFrame(F1)     // VIDEO ONLY
  UI event → paint chrome @ HDMI W×H → chrome DDR band / list
             → doorbell chrome plane (not F1)
  RTL: ascal(video) → plex_chrome blend → osd → HDMI
```

Align with w-fit `chrome-post-scale-plane-design.md`:

| Inc | RTL | ARM |
|-----|-----|-----|
| Inc-1 | HW rect post-ascal, 0 M10K | optional enable bit only |
| Inc-2 | N=4..8 line FIFO + DDR dirty band | **paint bottom HUD @ outW×outH** |
| glyph opt | font ROM | display-list instead of full band |

**ARM default path for product HUD:** Inc-2 **dirty band** (bottom panel only),  
RGB565 + color key, double-buffered. Full 1920×1440 every frame = **forbidden**  
(CPU + DDR).

---

## 2. Where ARM learns OUTPUT resolution

### Verified sources

| Source | Works today? | Notes |
|--------|--------------|-------|
| `/media/fat/MiSTer.ini` `[Plex] video_mode=` | **YES** | `mister_video_mode.hpp` — index 12→1920×1440; used in log `output=` |
| `status[4]` → `content_width/height` | **NOT HDMI** | `Plex.sv:226-228` only; **zero consumers** in `rtl/` or `sys/` (rg fanout = definitions only). ABI for content 320/640 **OSD tier**, not output raster, not wired into present_core/ddr_frame_store on this RBF class. |
| Live ascal `WIDTH`/`HEIGHT` | **NOT to daemon** | `sys_top.v` holds them; no misterplexd SPI read |
| DECODE conf 624×480 | Wrong for chrome | Streaming content |

### Finding (plain)

**Daemon can learn output mode from MiSTer.ini today.**  
It **cannot** read live scaler WxH from the core on this RBF class without a new status/mailbox.

**Minimum change for plane=1 v1:** `loadMisterVideoMode()` at start + on conf reload.  
If `!ok` → stay `plane=0` (F1 chrome), never invent 1080p.

**Minimum RTL add (w-fit/w-geom, recommended):** latch `hdmi_width/height` into a  
readable status word so runtime mode changes work without ini parse.

`content_width/height` must **not** be used as output size (wrong meaning).

---

## 3. Scale model (800×600 / 640×480 / 240p)

```text
outW,outH = video_mode (ini or mailbox)
L = computeOutputChromeLayout(outW, outH)   // mister_video_mode.hpp
  bodyScale = clamp(2..8, round(outH/240))
  margin, panelH from fractions; snap even
  font 12×16 if outH>=480 else 8×13
```

| Mode | out | bodyScale | advance px (12×16 or 8×13) |
|------|-----|----------:|---------------------------:|
| 12 | 1920×1440 | 6 | 78 |
| 8 | 1920×1080 | 4–5 | 52–65 |
| 5 | 800×600 | 2–3 | 26–39 |
| 6 | 640×480 | 2 | 26 |
| 240p-class | 320×240 | 2 | 18 (8×13) |

G0 gate: `tests/unit/test_chrome_output_layout_static.py`.

Paint API (Inc-2):

```text
paintChromeBand(rgb565_or_list, outW, outH, dirtyRect)
// dirtyRect ≈ panel only: y in [outH - panelH - margin, outH)
// stride = outW * 2; key color transparent
```

---

## 4. Cost (coordinate w-cpu-1)

Parent load lock: SYSTEM_BUSY **~169/200 (84.5%)**, misterplexd **~25.6**,  
Main **~90.6**, ffmpeg **~69.6** (w-cpu-1 `OVERLAY_COST_AND_MISTER.md`).

### Measured / cited today (F1 path)

Evidence log (480p present_profile): when chrome not forced,  
`overlay_us_p≈0..1`, `overlay_cpu_us_p≈0` — overlay often idle.  
Dirty F1 YUV paint host bench ~0.5–1 ms class at 624 (w-cpu); **A9 absolute UNKNOWN**.

### Proposed plane path cost model

| Work | Cadence | Bytes (mode 12, panel ~360 px tall full width) | ARM CPU |
|------|---------|-----------------------------------------------:|---------|
| Full 1920×1440 RGB565 every frame | 60 Hz | 5.5 MB ×60 = 331 MB/s write | **Do not ship** |
| Dirty band 1920×360 RGB565 | **UI event only** | ~1.4 MB **once** per show/seek | ESTIMATE low ms on A9 once |
| Progress bar strip 1920×8 | ≤4 Hz | ~30 KB ×4 | negligible |
| Display-list ~32 cmds | UI event | &lt;1 KB | **≪1 ms** target |
| Steady playback, chrome hidden | 0 | 0 | **0** |

**Hard rules vs 84.5% busy:**

1. **Never** call native chrome paint from `presentCleanFrame` hot path.  
2. **Never** full-frame software composite every video frame.  
3. Remove F1 `renderOverlay(cleanFrame)` when `plane=1` → **saves** current dirty YUV blend on present path (w-cpu benefit).  
4. Gate before ship (parent runs): `PRESENT_PROFILE=1`, force chrome ≥30 UI publishes,  
   `present_us_p99 < 35000`, ledger loss not worse than baseline, `p_ge50` Δ≤0.03  
   (w-cpu-1 gates — do not use `drops`/drift).

**DDR scanout contention** (rd-review): plane read BW at HDMI is **RTL/w-fit**  
problem (banded prefetch, dirty height). ARM cost is **write on UI events**.  
ARM must not spam chrome doorbells (that recreates publisher load).

---

## 5. Code change plan (when RBF feature bit lands)

### 5.1 Feature detect

```text
chromePlaneLive_ = conf CHROME_PLANE=1 OR status bit from RBF
// fail closed: bit absent → plane=0 legacy
```

### 5.2 `presentCleanFrame` (the fix at the cited line)

```text
if (!chromePlaneLive_) {
  renderOverlay(cleanFrame);     // TODAY 3156/3162
} else {
  // VIDEO ONLY — do not touch cleanFrame with chrome
}
publishDdrFrame(...);            // unchanged video path
// optional: if overlay visible && plane needs progress tick: scheduleChromePublish()
```

### 5.3 UI paths

```text
show()/pause/seek/stop:
  if (chromePlaneLive_) publishNativeChrome();  // outW×outH band
  else /* existing F1 path including publishPausedOverlayFrame */
```

### 5.4 Pause loop 50 ms republish

```text
if (chromePlaneLive_) {
  // hold plane; do NOT 50ms F1 overlay republish
} else {
  // existing Test B sticky path
}
```

### 5.5 ABI with w-fit (placeholder until fit publishes numbers)

```text
chrome_phys_base   // TBD vs 0x3000_0000 F1 map — must not collide
chrome_stride      = outW * 2
chrome_dirty_y0/y1
chrome_doorbell
chrome_key         = 0x0001
```

---

## 6. Coordination checklist (same RBF)

| Owner | Deliverable |
|-------|-------------|
| w-geom T7 | V_STORE 240→480 (content + interim overlay benefit) |
| w-fit-1 | post-ascal plane + band FIFO; H_DE stays 529 class |
| w-osd-hires | this design; skip `renderOverlay` on plane=1; native painter |
| w-cpu-1 | profile gates; Main reclaim if present_us tight |

**Invisible if:** ARM ships without plane RBF, or plane RBF without ARM skip of F1 bake  
(double chrome or still-soft F1 chrome).

---

## 7. Acceptance (parent pixels)

1. Log: `plane=1 canvas=<outW>x<outH>` not `canvas=624x480`.  
2. Sharpness: `score_overlay_output_native.py` PASS on pause grab.  
3. Low modes: ini 5/6/240p — panel in-bounds, legible (G0 + lab).  
4. CPU: w-cpu gates on present_us / p_ge50.  
5. No F1 chrome: grep path must not `renderOverlay` when plane live (unit pin).
