# Native 720p core raster vs glass 720p — verdict

**MEASURE_REF (ascal / product path):** detached worktree  
`HEAD_BRANCH=HEAD` (detached) · `HEAD_SHA=3fa01a9b` · full `3fa01a9b98d0ee7ed37d68775f9af50f7845d163`  
Path: `/home/flynnsbit/Projects/MisterPlex-wt-clock-pin-3fa01a9b`

**w-clock tip (this answer):** `w-clock-bump` — see `git rev-parse` at commit.

---

## Verdict: **(c) NEEDED ONLY IF …** — and for **glass 720p alone: (b) NOT NEEDED**

| Question | Answer |
|----------|--------|
| Is a native 720p **core** raster required for **glass** 720p? | **NO — (b)** |
| Is the PLL 20→24/30 MHz fit kit load-bearing for video_mode=0? | **NO — park it** |
| When is a faster/wider core raster still useful? | **(c)** see below |

**CDC 4:15 / PLL bump work is PARKED with the kit.** No further PLL edits until parent unparks.

---

## Quoted path (MEASURED @ 3fa01a9b)

### ascal owns HDMI geometry when not Direct-Video raw

`sys_top.v` ascal (≈714–780):

```systemverilog
.i_clk    (clk_ihdmi),   // == clk_vid
.i_ce     (ce_hpix),
.i_de     (hde_emu),
.iauto    (1),           // auto-detect input size from DE
.o_clk    (clk_hdmi),    // == hdmi_clk_out (video_mode PLL)
.hdisp    (WIDTH),       // HDMI mode width (1280 for video_mode=0)
```

`sys_top.v` ≈1712: `assign clk_ihdmi = clk_vid;`

`Plex.sv` ≈825–826:

```systemverilog
assign CLK_VIDEO = clk_sys;   // 20 MHz product
assign CE_PIXEL  = ce_pix;
```

`sys_top.v` ≈1264–1267 HDMI TX clock select:

```systemverilog
.clkselect({1'b1, ~vga_fb & direct_video}),
.inclk({clk_vid, hdmi_clk_out, 2'b00}),
```

`sys_top.v` ≈1317–1320 data mux:

```systemverilog
hs/vs/de/d <= (~vga_fb & direct_video) ? hdmi_dv_* : hdmi_*_osd;
```

With lab `direct_video=0` (parent-measured): mux takes **hdmi_*_osd** (post-ascal).  
Output raster = **HDMI PLL / video_mode**, not core H/V totals.  
Parent: video_mode=0 → **1280×720@60 glass**. Core 640×480 content is **upscaled** (capture 4:3 pillar) — agrees with this wiring.

**ascal does not wire-bypass at 1:1** (w-nostub): feeding 1280×720 **input** is a **resample-quality** win, not required for glass mode existence.

### Product core input to ascal today

Default `present_core` (**no** `PRESENT_BEAM_960`): `colorbars` **H_DE=529**, line wrap **638** (`colorbars.sv` 38–39).  
`FRAME_W×FRAME_H` store is **stretched** into 529 DE (`present_core` STORE_X_SCALE).  
ascal `iauto` sees ~529×~480-class DE and scales to 1280×720 out.

---

## What the PLL kit was buying (honest)

Fit kit (`.agent-work/w-clock/fit-native-720p24/`) aimed to make the **core emit** 1280×720@~24 Hz into ascal.

That does **not** change `o_clk` / `hdisp(WIDTH)` glass mode.  
It only changes **i_*** sample grid quality/rate.

| Goal | Native 720p core raster + PLL? |
|------|--------------------------------|
| Glass 720p@60 | **Not needed** — video_mode + ascal |
| Avoid 4:3 pillar of 640 content | **FRAME_W/H + content**, not core CEA timing |
| 1:1 (or near) ascal input samples of 1280-wide frame | **Wide content DE**, not necessarily 24 MHz PLL |
| Core progressive refresh ≥24 Hz at 1280×720 min-blank 1ppc | **Needs ≥23.175 MHz** (or 2ppc/other) — PLL kit class |

---

## (c) Conditions where core raster / PLL still matters

Unpark PLL / wide beam **only if** parent wants one of:

1. **Input-side sample density:** ≥1280 unique horizontal samples/line into ascal (not 529-stretch of a 1280 store).  
2. **Core display tick ≥24 Hz** while scanning full 1280×720 min-blank 1ppc:  
   - `1312 × 736 × 24 = 23.175 MHz` (MEASURED arithmetic)  
   - At **20 MHz**: `20e6/(1312×736) ≈ 20.71 Hz` max — **underspeed vs 24** content cadence (hold/repeat still works; tick ≠ 24).  
3. **Direct Video raw** ever enabled with nonstandard beam — then glass ≠ video_mode (lab currently DV=0; VGA_SCALER=1 on w-clock is defensive).

**CEA 1650×750@24 = 29.70 MHz** remains the full CEA number (`present_video_timing_720p.sv` header @ 3fa01a9b).  
**Not required** for glass; only for true CEA input timing.

---

## New task: 1280×720 **content** @ 24 fps with **clk_sys=20 MHz**

### Write side (into frame store)

**HPS/ARM** fills YUV420 banks in DDR (`ddr_frame_store` is primarily **read** for present).  
Write pixel rate is **not** tied to core `ce_pix` / 640 geometry.

Bandwidth (INFERRED bytes, standard 420):  
`1280 × 720 × 1.5 × 24 ≈ 33.2 MB/s` — w-mem territory; no PLL.

Nothing in w-clock present path **writes** one clk_sys cycle per content pixel for the HPS path.

### Read / present side @ 20 MHz (what can break)

| Mode | Unique samples/line | 1280 store | Notes |
|------|---------------------|------------|--------|
| Product Template H_DE=529 | **529** | Stretched/decimated | Works; **quality** loss; no PLL |
| BEAM_960 max 960 DE | ≤960 | Needs FRAME 960×540 today | **Incompatible** with FRAME_1280 without retarget |
| True 1280 DE 1ppc min-blank | 1280 | Identity map | **fps≤~20.71** @ 20 MHz; OK for ascal→60 |
| CEA 1650×750 1ppc | 1280 | Identity | fps≈16.16 @ 20 MHz (pack header) |
| MULTI 2ppc same-clock | **scan-out still ≤20 Mpix/s** | See pack comment | Does **not** magically hit 29.7 Mpix/s on CE_PIXEL |

**Silent assumptions tied to 640×480-class geometry (MEASURED):**

1. `colorbars` fixed **H_DE=529** / 10-bit hc — not 1280 DE.  
2. `PRESENT_BEAM_960` elab `$error` if `FRAME_W!=960` — cannot just set FRAME_1280 + BEAM_960.  
3. `Plex.sv` ties `.content_w/h(11'd0)` — no PLXG live size on product.  
4. `present_video_timing_720p` / `_960` are **noprune packs** on default path — **do not drive HDMI**.  
5. `present_pix_rate_match` only under `PRESENT_CLK_PIX_PLL` (off).  
6. `STORE_X_SCALE = (FRAME_W * 39647)/320` still **compiles** at 1280; behavior is stretch into 529, not identity.

**FRAME_W=1280 FRAME_H=720 at 20 MHz will FIT (w-nostub M10K) as a bank size** without PLL.  
**It will not automatically present 1280 unique samples/line** until a beam/DE path is enabled for that size (new L4 work), or MULTI path is completed carefully.

### Recommended near-term (no PLL)

1. **FRAME_1280** store + HPS 24 fps fill (w-mem/path).  
2. Keep **clk_sys=20 MHz**.  
3. Present: either accept Template stretch (ship quality known-bad for HD) **or** add **content DE ≥1280** (or 960 tier first) under explicit macros — beam may run **~20.7 Hz** into ascal; cadence holds 24 fps content.  
4. **Park** native-720p24 PLL kit + CDC 4:15 primary; demote to optional quality epic.  
5. VGA_SCALER=1 remains good product policy (defensive); not load-bearing in this lab.

---

## Ladder @ main `3fa01a9b` (pinned detached)

files.qip **45** `set_global_assignment` lines (parent).  
Product QSF: `FRAME_W=640` `FRAME_H=480`; `PRESENT_BEAM_960` **commented**; `use_frame_store=0`.

| Module | ON_MAIN | IN_FILES_QIP | INSTANTIATED | ENABLED | Level |
|--------|---------|--------------|--------------|---------|-------|
| present_core | yes | yes | yes (Plex.sv) | yes | **L4** |
| present_cadence | yes | yes | yes (present_core) | yes | **L4** |
| present_video_timing_720p | yes | yes | yes (noprune pack) | **obs only** (not HDMI) | **L3*** |
| present_video_timing_960 | yes | yes | yes (noprune pack) | obs only | **L3*** |
| present_beam_content_de | yes | yes | yes under BEAM_960 | **no** (macro off) | **L2** |
| present_beam_ppc | yes | yes | under MULTI | **no** | **L2** |
| present_npx_path | yes | yes | under MULTI | **no** | **L2** |
| present_pix_rate_match | yes | yes | under CLK_PIX_PLL | **no** | **L2** |
| yuv_bt601_npx | yes | yes | under MULTI | **no** | **L2** |
| present_content_window | yes | yes | **0** in hierarchy | no | **L2 dead** |
| present_geom_latch | yes | yes | **0** | no | **L2 dead** |
| plex_present_geom_mux | yes | yes | **0** | no | **L2 dead** |
| present_vtotal_bresenham | yes | yes | **0** (main core) | no | **L2 dead** |

\*L3 noprune: compiled and instantiated but **does not enable** 720p raster on glass.

w-clock branch extras (NBA B20, VGA_SCALER always-1, PLL kit docs): **ON_MAIN=no** until parent merges.

---

## Parked artifacts

| Artifact | Status |
|----------|--------|
| `fit-native-720p24/*` PLL 24/30 + SDC | **PARKED** — not fit-critical for glass 720p |
| CDC 4:15 blocker / 30 MHz primary | **PARKED** with PLL |
| VGA_SCALER=1 (`d24d045c`) | Keep; defensive product policy |
| B20 NBA / PLXG fences | Still open; orthogonal |

**Ship-proof for native core 720p@24 PLL: N/A (retired as near-term requirement).**
