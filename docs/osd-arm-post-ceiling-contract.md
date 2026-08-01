# ARM contract after the 529×240 ceiling is lifted (w-osd-hires)

**Status:** coordination doc — no fit, no device claims.  
**Peers:** w-geom (RTL ceiling / measurement), w-fit-1 (`docs/chrome-post-scale-plane-design.md` post-ascal plane).  
**Parent root cause (accepted):** product `FRAME_W/H=640/480`, `V_STORE=240`, sole `present_core` RGB → ARM-only F1 paint cannot fix glass sharpness.

---

## 1. What composites the player overlay TODAY (quoted)

### ARM — three entry points, one bank geometry

**Idle / STOPPED** — `media_player.cpp` `paintIdle()`:

```text
g = plex480pDdrFrameGeometry();          // coded 624×480
overlay_.renderRgb24(rgb, cw, ch);
// … RGB→I420 …
publishDdrFrame(frame, "idle DDR", …);
```

**Pause (sticky)** — `publishPausedOverlayFrame()` ~769–849:

```text
g = plex480pDdrFrameGeometry();
overlay_.renderYuv420p(yuv, cw, ch);
publishDdrFrame(frame, "pause overlay DDR", …);
```

**Play / timeline** — lambdas ~2995–3195:

```text
rawW/rawH = ddrGeometry.coded_*     // product bank, not HDMI
renderOverlay(data) → overlay_.renderYuv420p(data, rawW, rawH)
presentCleanFrame → publishDdrFrame(..., "playback DDR")
```

Renderer: `host/libmisterplex/playback_overlay.hpp`  
`PlaybackOverlay::compute(w,h)` / `renderYuv420p` — metrics from **buffer W×H** (today always bank).

### RTL — sole path, no chrome bypass

```text
Plex.qsf:83-84     FRAME_W=640 FRAME_H=480
present_core.sv:161-164
  H_DE=529  V_STORE=240
  STORE_Y_SCALE=(FRAME_H*65536)/240 = 2.0 exactly
present_core.sv ~239  ddr_frame_store(.rd_x(store_x),.rd_y(store_y),…)
Plex.sv ~712 wire [7:0] r,g,b;
Plex.sv ~730 present_core present(…);
Plex.sv ~854 assign VGA_R = r;   // sole driver into MiSTer video path
sys_top.v ~714 ascal → ~1183 osd (F12 menu only) → HDMI
```

**Finding:** player chrome is **pixels inside the F1 YUV bank**, not `osd.v`. Ceiling applies.

---

## 2. What ARM must do once the ceiling is lifted (plane=1)

When w-fit Inc-2+ exposes a post-ascal chrome plane:

| Today (`plane=0`) | Required (`plane=1`) |
|-------------------|----------------------|
| Author at `plex480p` 624×480 | Author at **HDMI W×H** (output raster) |
| `render* → publishDdrFrame` F1 | Paint chrome DDR band / display list; **do not** bake transport into F1 |
| F1 still carries video+chrome | F1 = **video only**; chrome plane separate |
| Log `canvas=624x480 … plane=0` | Log `canvas=<outW>x<outH> … plane=1` |

### Where ARM learns output resolution

| Source | Status |
|--------|--------|
| `/media/fat/MiSTer.ini` `[Plex] video_mode=` | **Implemented:** `mister_video_mode.hpp` + log `output=` (`f18223ab`) |
| Live `sys_top` WIDTH/HEIGHT via SPI | **Not wired** — finding; minimum change = status word or keep ini if mode static |
| DECODE conf | **Must not** drive chrome size |

**Minimum change if ini-only:** ship with `loadMisterVideoMode()`; fail closed (`plane` stays 0) if `!ok` — never invent 1080p.  
**Better:** w-geom/w-fit expose latched `hdmi_width/height` in a mailbox so ARM tracks runtime mode changes without re-reading ini.

### Layout (scale to 800×600 / 640×480 / 240p)

Use **output** metrics (already in tree):

```text
computeOutputChromeLayout(outW, outH)   // mister_video_mode.hpp
bodyScale = clamp(2..8, round(H/240))
// mode12 1440 → scale 6; 480 → 2; 240 → 2; panel in-bounds (G0 gate)
```

Do **not** reuse bank `PlaybackOverlay::compute` with h=480 when plane=1 — that freezes 12×16@2 forever.

G0: `tests/unit/test_chrome_output_layout_static.py` (true rc=0 on host).

---

## 3. Coordination matrix

| Owner | Delivers | Blocks glass fix if missing |
|-------|----------|------------------------------|
| **w-geom** | Ceiling / fabric truth; any V_STORE or measurement T7 | Wrong architecture if F1 still assumed |
| **w-fit-1** | Post-ascal `plex_chrome` (Inc-1 HW rect → Inc-2 band); fit slot | Sharpness impossible without this |
| **w-osd-hires (this)** | Output layout, mode parse, plane writer, **stop F1 chrome when plane=1**, B3 cadence rules | Soft mush remains if ARM still paints F1 |

**Land together:** RBF with plane + ARM that sets `plane=1` and stops `renderOverlay` into F1.  
ARM-only deploy on old RBF: keep `plane=0` path (safe degrade).

---

## 4. B3 — Sharp but juddering? (answered from code)

Parent instruments: publish-side judder real (`acf lag1=-0.1950`). Question: does sharp chrome inherit it?

### Today (F1-composited chrome) — **YES, can judder with publish**

**Pause loop** (`media_player.cpp` ~3285–3308):

```text
if (paused_ && overlay visible):
  presentCleanFrame(...) or publishPausedOverlayFrame()
  sleep 50ms
  // every ~20 Hz: full-bank doorbell via publishDdrFrame
```

**Play with chrome** (`presentCleanFrame` every decoded frame):

```text
renderOverlay(cleanFrame);   // bake chrome into video pixels
publishDdrFrame(...);        // same bank-swap path as bare video
```

Chrome is **not** a held plane; it is **re-doorbelled with F1**. Any bank-swap / present cadence defect that judders video **also moves chrome** (edges phase with the same swaps).

### After post-ascal plane — **depends on update policy**

| Chrome update policy | Inherits video publish judder? |
|----------------------|--------------------------------|
| **A. Per video frame** ARM rewrite + plane swap lockstep with F1 | **YES** — sharp-but-juddering risk |
| **B. Event-driven** (show/hide/seek/pause; progress bar ≤4 Hz) + RTL **hold** last buffer across HDMI vsyncs | **NO** for static chrome; video may still judder underneath |
| **C. RTL HW rect Inc-1** (no ARM cadence) | **NO** |

**Contract for w-osd + w-fit (required for a real fix):**

1. Default **policy B** — do not call chrome publish from the video present hot path.
2. Progress bar: timer ≤4 Hz or on seek only, not every `presentCleanFrame`.
3. Pause: **one** chrome publish when entering pause / when UI changes; **not** the 50 ms F1 republish loop (that loop exists to fight Test B wipe on F1 — obsolete once chrome is not in F1).
4. Feature bit: if `plane=0`, keep today’s F1 path (including 50 ms loop).

**Answer to rd-review B3:**  
Fixing sharpness **alone** (plane) while still pushing chrome every video frame **can** yield sharp-but-juddering chrome.  
**Preventable** by event-driven hold (B). That is an ARM+RTL protocol requirement, not automatic.

---

## 5. What this worker will / will not do

| Will | Will not |
|------|----------|
| Keep output mode parse + layout G0 | Claim ARM-only glass sharpness |
| Prep `plane=1` writer against w-fit ABI when published | Start Quartus / touch device |
| Stop F1 `renderOverlay` when plane live | Ship bodyScale=3 as the user fix |
| Document B3 hold policy | Parallel chrome RTL vs w-fit |

---

## 6. Parent commands (when scoring later)

```bash
# Layout scales (host)
python3 tests/unit/test_chrome_output_layout_static.py; echo "true rc=$?"

# Mode parse
make build/test_mister_video_mode && ./build/test_mister_video_mode; echo "true rc=$?"

# After plane RBF+ARM: sharpness ≠ judder — separate tests
# sharpness: tools/score_overlay_output_native.py GRAB.png
# judder: parent acf / hold histogram on chrome edge vs video (policy B → chrome stable)
```
