# RTL proposal: `plex_chrome` — output-resolution overlay plane

**Owner:** w-osd-hires · **Status:** design only — **no Quartus fit**  
**Tip context:** ARM bank chrome + fail-closed `plane=1` scaffolding  
**Strategic drivers (parent):**
1. User bug #2 — HUD must match **applied** MiSTer output res, not content/bank.  
2. User direction — **offload ARM** to fabric/BRAM/DDR.  
**One plane serves both:** post-ascal composite + semantic list (ARM stops per-frame pixel bake).

**r-misterfin (2026-08-01) — geometry discovery CLOSED:**
- ARM **cannot** read applied HDMI timing (Main `v_cur` write-only via `UIO_SET_VIDEO`; `UIO_GET_VRES` = core DE).  
- Fabric **already has** applied size: `HDMI_WIDTH`/`HDMI_HEIGHT` (`emu_ports.vh:34-35` ← `sys_top.v:909-910`).  
- ⇒ **RTL self-sizes from those wires + DE counters. Zero ARM discovery required for scale.**  
- ARM `output=DEFAULT_ASSUMED` stays honest; INI parse only as labelled `source=ini` intent fallback for logs/preview — **not** plane geometry authority.

---

## 0. Budget baseline — which fit is “the device”

| Artifact | ALM | M10K | bits | DSP | Notes |
|----------|----:|-----:|-----:|----:|-------|
| **`remote_out/fit-t7b-prog480/Plex.fit.rpt`** | **23,585 / 41,910** | **465 / 553 (84%)** | **2,997,709 (53%)** | **44 / 112** | Matches fixture `fabric_decode_fit_hierarchy_8fdf440f.excerpt.rpt` totals |
| `output_files/Plex.fit.rpt` | 21,082 / 41,910 | 465 / 553 (84%) | same 53% bits | **74 / 112** | Older/local tree — **do not use for deployed `8fdf440f` class** |

**Deployed-RBF class for design:** treat **t7b / 8fdf hierarchy** as binding  
(ALM **23,585**, M10K **465**, DSP **44**). Free: ALM **18,325** · M10K **88** · DSP **68**.

**M10K packing lesson (same reports):** **84% of blocks hold only 53% of bits** → many shallow/narrow memories.  
Chrome ROMs/lists must be **few deep/wide stores**, not dozens of tiny RAMs. Consolidation is cheaper than “88 free blocks ⇒ 88 small buffers.”

### `decode_stub` reclaim funding (corrected argument)

| Claim | Status |
|-------|--------|
| Old: `host_owns_fs` alone proves stub dead | **Withdrawn** (parent) |
| **Shipping:** `DDR_FRAME_STORE=1` → `present_core` uses `ddr_frame_store` (`:225-290`); **`.wr_en(fs_wr_en)` only in `` `else `` SDRAM `frame_store` (`:303`)** | **Cited** — write port of stub path **physically unconnected** on product macro |
| Also: `Plex.sv:478-482` `ddr_swap=1'b0` / `ddr_wr_en=1'b0` under `DDR_FRAME_STORE` | Reinforces host DDR ingest is F1 doorbell path, not stub |
| Hierarchy cost on 8fdf class | **`decode_stub`: 9,216.9 ALM · 268 M10K · 2,124,800 bits** (fixture line `\|decode_stub:stub\|`) |

Post-reclaim free M10K ≈ **88+268 ≈ 356** (map before spending). w-fit-1 owns reclaim.

---

## 0b. Decisive product finding

| Path | Can fix user bug #2? |
|------|----------------------|
| ARM composite into F1 624×480 | **No** — stretched by `present_core`+ascal |
| Framework `sys/osd.v` | **No** — 256×64, Main SPI, dead during play (`SUSPEND_MAIN`) |
| **Post-ascal `plex_chrome` on `clk_hdmi`, self-timed** | **Yes** — 1:1 output pixels |

ARM-only ship = bank sharpness only. Full fix = this RTL + ARM **semantic** list writer.

---

## 1. Where it taps (quoted RTL)

### HDMI path today (`sys_top.v`)

```text
ascal (o_clk=clk_hdmi)     ~714–768
  → hdmi_data / hs / vs / de
shadowmask                 ~1159–1174
  → hdmi_data_mask
osd hdmi_osd               ~1183–1200   // F12 menu only, 256×64
  → hdmi_data_osd → pins
```

Evidence:
- `sys_top.v:712` `clk_hdmi = hdmi_clk_out`
- `sys_top.v:764-772` ascal `.o_r/g/b` → `hdmi_data`
- `sys_top.v:1183-1200` `osd` blends on `clk_video(clk_hdmi)` after mask

### Proposed insertion (framework-legal — copy **osd pattern**, not size)

```text
ascal → shadowmask → [plex_chrome NEW] → osd hdmi_osd → HDMI
                         ↑
         clk_hdmi, din/hs/vs/de
         HDMI_WIDTH / HDMI_HEIGHT (applied)
```

**Stock OSD pattern to copy** (`sys/osd.v:26-36`):
- Fixed **logical** buffer; **integer nearest-neighbour expand** from measured post-ascal DE.  
- Self-times in fabric; host only pushes **bytes/commands**, not scanout pixels.  
- Unusable as-is (256×64, Main SPI, suspended in play) — **structure is right**.

**Why after shadowmask, before `osd`:**
- Same stage class as framework OSD (proven composite after ascal).
- F12 menu stays on top of player chrome (correct z-order).
- Does not touch `present_core` / F1 (w-geom scaler is a separate pre-ascal/F1 problem).

**If post-ascal were blocked** (it is **not**): pre-ascal DE blend ceiling = core DE — **fails user**. Not proposed.

### Clock / CDC

| Domain | Role |
|--------|------|
| `clk_hdmi` | DE counters, glyph NN expand, RGB blend (hot path) |
| `clk_sys` / HPS DDR mailbox | List write, enable/seq (ARM semantic channel) |
| CDC | Dual-clock list RAM (sys/HPS write · hdmi read) or vsync shadow |

### Geometry authority — **fabric only**

```verilog
// sys_top.v:909-910 — applied output (Main-latched WIDTH/HEIGHT ± HSET/VSET/PR)
hdmi_height <= (VSET && (VSET < HEIGHT)) ? VSET : HEIGHT;
hdmi_width  <= (HSET && (HSET < WIDTH))  ? HSET << HDMI_PR : WIDTH << HDMI_PR;
// emu_ports.vh:34-35 → every core sees:
input [11:0] HDMI_WIDTH, HDMI_HEIGHT;
```

**`plex_chrome` sizing/scale:**
1. Prefer running **hx/hy from DE** (osd-style self-time).  
2. `bodyScale = clamp(2..8, half_even_round(HDMI_HEIGHT/240))` in fabric (or equiv. from measured DE height).  
3. **Never** trust ARM WxH for pixel placement.

**ARM telemetry (optional, not load-bearing):**
- Keep `output=DEFAULT_ASSUMED` / `source=ini` labels honest.  
- Optional **PLXO** FPGA→ARM mirror of `HDMI_WIDTH/HEIGHT` + `chrome_hw` for logs and list **preview** only — list coords still use same formula ARM already has for preview; fabric re-derives scale from HDMI_* if ARM is wrong.

---

## 2. Storage options — M10K cost (pack against 84%/53%)

Full-frame BRAM is impossible: 1920×1080 RGB565 ≈ **1620+ M10K** ≫ 88.

| Option | What ARM writes | Fabric storage | Est. M10K blocks | Est. bits | ARM CPU | Sharp @ output? |
|--------|-----------------|----------------|-----------------:|----------:|---------|-----------------|
| **A. Semantic list + consolidated font/icon ROM** | cmds only | **1–2** deep ROM + **1** dual-port list | **8–16** | ~100–200 kbit | event ≪1 ms | **Yes** |
| **B. ARM BRAM band** (panel RGB565) | pixels | 2× 1920×160×16 | **~96–120** shallow | ~1.2 Mbit | paint | Yes — **no fit in 88** |
| **C. DDR strip + line FIFO** | pixels→DDR | 2–4 line FIFO | **4–8** | small | paint+DDR | Contends F1 |

### Option A — packing rule (binding)

Because **84% blocks / 53% bits**, do **not** allocate one M10K per glyph plane.

| Logical content | Preferred implementation | Target M10K |
|-----------------|--------------------------|------------:|
| Fonts 12×16 + 8×13 + icons 1bpp | **Single** wide/deep `altsyncram` (or 2) with address map | **2–4** |
| List double-buffer 2×256×64b (not 512 unless needed) | **One** true dual-port or 2-bank simple dual | **2–4** |
| Span index | fold into list walk if ALM allows; else 1 deep RAM | **0–2** |
| **Total A** | consolidated | **≤12** preferred, **hard cap 24** |

Pause UI ≪ 64 cmds — 256-entry list is enough; avoid oversizing RAM “for later.”

### Option B — needs stub reclaim

~120 M10K band → **blocked** until w-fit-1 stub out (~356 free). Not required for text/icons.

### Option C — escape hatch only

**Primary ship path = A.** Inc-1: solid rect **0 M10K** to prove post-ascal blend.

---

## 3. ARM interface — semantic only, doorbell-relative

### Principle

ARM sends **meaning** (state, progress fraction, glyph codes, icon ids, optional layout hints).  
**RTL owns scale + pixel expand** from `HDMI_HEIGHT` / DE (osd NN pattern).  
That **removes** `renderYuv420p` bake from the play loop when `plane=1` — offload goal met.

ARM does **not** need applied timing API for correctness. Optional coords in list should be  
computed with the **same** half-even H/240 rule; fabric may ignore ARM scale field and  
recompute from `HDMI_HEIGHT` (recommended: ARM sends **unscaled logical** units OR  
output px using ini preview — fabric clamps).

### Address map (MUST be doorbell-relative)

**Never hardcode absolute phys** — `DOORBELL_PHYS + offset` only  
(`mailbox_abi_spec.hpp`, `BANK_MAILBOX = DOORBELL + 0x128`).

| Offset | Tag | Dir | Purpose |
|-------:|-----|------|---------|
| +0x128 | PLXD | F→A | bank (existing) |
| **+0x130** | **PLXC** | A→F | chrome list control / seq doorbell |
| **+0x138** | **PLXO** | F→A | optional: `HDMI_WIDTH/HEIGHT` mirror + `chrome_hw` + gen (**telemetry**, not authority) |
| +0x140… | list payload | A→F | cmds in DDR page or small dual-port filled via same window |

Add to `mailbox_abi_spec.hpp` + `test_rtl_invariants.py` before RTL merge.

### PLXC control word (illustrative 64-bit)

```text
[31:0]  magic 'PLXC'
[32]    enable
[33]    bank_sel          // which list buffer is live
[47:34] cmd_count         // 0..256
[63:48] seq               // monotonic; fabric latches on vs after seq change
```

### Command ISA (64-bit, ≤256 cmds)

| op | Fields |
|----|--------|
| `RECT` | x,y,w,h, rgba8 — panel / bar track |
| `GLYPH` | x,y, code, font_id, rgba8 — **scale from fabric HDMI_HEIGHT** |
| `ICON` | x,y, id, rgba8 |
| `BAR` | x,y,w,h, fill_w (ARM-precomputed fraction→px using preview W, or logical 0..1024) |
| `END` | — |

Prefer **fabric multiplies** only if needed; default **ARM fill_w in output px using ini preview** with fabric clip — **0 DSP**.

Pause chrome ≪ 64 cmds. Build on **UI event only**, not every video frame.

### Feature enable (fail closed)

```text
chromePlaneLive = CHROME_PLANE conf ∧ PLXO.chrome_hw   // or status bit
```

Scaffolding: `MediaPlayer::chromePlaneLive()` skips F1 bake when live.

---

## 4. Scaling rule (fabric-authoritative)

```text
// In plex_chrome (clk_hdmi), osd-style:
meas_h = HDMI_HEIGHT  // or DE-measured frame height
bodyScale = clamp(2..8, half_even_round(meas_h / 240))
font_id   = (meas_h >= 480) ? FONT_12x16 : FONT_8x13
// Glyph draw: nearest-neighbour expand by bodyScale (copy osd integer expand idea)
```

| Mode | H | bodyScale | cellH |
|------|--:|----------:|------:|
| 240p | 240 | 2 | 26 |
| 640×480 | 480 | 2 | 32 |
| 800×600 | 600 | 2 | 32 |
| 1080p | 1080 | 4 | 64 |
| 1440p | 1440 | 6 | 96 |

**Host gap gate (plane=0 vs target):** `bank_cellH=32` vs `hdmi1080_cellH=64`.  
**Glass:** stem edge ≤2 px @ mode 12; not bank mush.

---

## 5. Budget versions (prereg vs t7b/8fdf baseline)

**Baseline (binding):** ALM 23,585 · M10K 465 · DSP 44 · bits 2,997,709  
Artifact: `w-fit-integ/.../remote_out/fit-t7b-prog480/Plex.fit.rpt` + `fabric_decode_fit_hierarchy_8fdf440f.excerpt.rpt`.

### V1 — fits **88 M10K free** (no stub dependency) — **ship target**

| Item | Pred. Δ | Notes |
|------|--------:|-------|
| M10K | **+8..16** (cap **24**) | consolidated ROM+list; leave ≥64 free |
| Block bits | **+~150 kbit** | small vs 2.99 Mbit baseline |
| ALM | **+1.5k..3.5k** | DE counters + bounded cmd walk + NN expand |
| DSP | **0** | ARM/logical bar fill |
| Timing | HDMI path **HOLD** | ≤16–32 active cmds/line; 2–3 stage blend |

**Hard fail before/after map:** M10K Δ > 24 preferred / **>40 absolute**, ALM Δ > 6k, or neg HDMI slack.

### V2 — after stub reclaim (w-fit-1) — optional

| Add-on | Pred. extra |
|--------|------------:|
| BRAM panel band (B) | +80..120 M10K |
| 2bpp fonts / more icons | +4..12 M10K |

Not required for bug #2. **Dependent on stub map.**

### Inc-1 (optional same fit)

Solid bottom rect + enable: **~0 M10K, ~0.3–0.8k ALM**.

---

## 6. Combined ONE-fit request (coordinate)

**ONE exclusive, not three.**

| Lane | Same RBF deliverable |
|------|----------------------|
| **w-fit-1** | Strip/gate `decode_stub` (write port already dead under `DDR_FRAME_STORE`) → reclaim ~9.2k ALM / 268 M10K; wire `chrome_hw` |
| **w-geom** | Content window + fabric scaler (delete ARM 320→618 @ 10.4 ms/f) — F1/`present_core` |
| **w-osd-hires** | `plex_chrome` V1 post-ascal list+ROM; ARM PLXC writer; `plane=1` fail-closed |

**Order in tree:** stub reclaim → w-geom F1 path → `plex_chrome` in `sys_top` → ABI invariants green.

**Combined prereg (chrome numbers firm; peers fill gaps):**

| Resource | Baseline (t7b/8fdf) | Chrome V1 Δ | Geom Δ | Stub reclaim | Net intent |
|----------|--------------------:|------------:|-------:|-------------:|------------|
| M10K | 465/553 | **+12±4** | TBD | **−268** | free ≫ 88 |
| ALM | 23585/41910 | **+2.5k±1k** | TBD | **−9.2k** | headroom |
| DSP | 44/112 | **0** | TBD | 0–1 (stub had 1) | — |
| HDMI timing | hold | hold | n/a | n/a | no neg slack |
| present_core timing | hold | n/a | hold | n/a | no neg slack |

---

## 7. ARM software after plane live

1. Read PLXO → applied WxH; build list via `fromOutputLayout`.  
2. Write list + PLXC.seq; fabric latches next vs.  
3. `chromePlaneLive()` → **skip** `renderOverlay` into F1 (`presentCleanFrame` already gated).  
4. Idle STOPPED / notices → same list path (clean logo = empty list + optional chevron as ICON or keep ARM idle YUV until chevron ROM).  
5. Conf `CHROME_PLANE=1` default off until parent glass PASS.

---

## 8. Sim / gates before exclusive slot

| Gate | What | RED/GREEN |
|------|------|-----------|
| G0 layout | `test_chrome_output_layout_static.py` + crispness modes | host rc=0 |
| G1 list ISA unit | encode PAUSED list → software walker golden vs `paintChromePlane` | host |
| **G2 host behavioral** | `tests/unit/test_plex_chrome_sim.cpp` + `plex_chrome_sim.hpp` | **shipped** |
| G2b Verilator | `rtl/plex_chrome.sv` + font ROM (after shell costs out) | sim |
| G3 solo map | hierarchical synth M10K≤40 ALM≤6k | **before** fit grant |
| G4 glass | parent pause grab edge sharpness | after ONE fit |

### G2 metric (measured, not OCR)

- **Fabric GREEN:** render semantic `PAUSED` list at HDMI W×H with `bodyScale=fabricBodyScale(H)`; every maximal **glyph** (near-white) H/V ink run length is a multiple of `bodyScale`; bbox height ≥ `8*scale`. Modes: 320×240, 640×480, 800×600, 1920×1080.
- **Bank RED:** author at 624×480 scale=2 then NN-stretch to 1920×1080 (product path). Assert fails fabric scale-4 metric (`hBad|vBad>0` **or** `cellH != 32`). Empty raster is **not** PASS (`ink>50` required).
- Skeleton RTL: `fpga/Plex_MiSTer/rtl/plex_chrome.sv` — **not in QSF**; ports + `body_scale_f` + DE shell only.

---

## 9. Explicit non-goals

- Replacing framework F12 `osd.v`  
- Full-frame BRAM or full-frame DDR overlay in V1  
- Claiming bug #2 shipped on bank ARM path  
- Mid-fit source edits  

---

## 10. Recommendation (one paragraph)

**Fund post-ascal `plex_chrome` V1:** copy **osd self-time + integer NN expand**, not osd size; size from **`HDMI_WIDTH`/`HDMI_HEIGHT` + DE** (r-misterfin: ARM cannot discover applied mode). ARM sends **semantic lists only** via **doorbell-relative PLXC**. Consolidated font/list RAM **≤12–16 M10K** (cap 24), **0 DSP**, **~2–3.5k ALM**, vs baseline **t7b/8fdf 23585/465/44**. Land in **one** fit with w-fit-1 stub reclaim (dead write port under `DDR_FRAME_STORE`) + w-geom scaler. Bank F1 chrome stays fail-closed until `chrome_hw` — **not** user-bug #2 fixed.

---

## 11. References

- `sys_top.v:714-768` ascal · `:909-910` hdmi_w/h · `:1159-1200` mask+osd  
- `sys/emu_ports.vh:34-35` `HDMI_WIDTH`/`HEIGHT`  
- `sys/osd.v:26-36` pattern (256×64 capacity wrong)  
- `present_core.sv:225-290` vs `:297-339` — `wr_en` only on non-DDR store  
- `Plex.sv:478-482` `ddr_swap=0` under `DDR_FRAME_STORE`  
- Fixture: `w-fit-integ/.../fabric_decode_fit_hierarchy_8fdf440f.excerpt.rpt` (`decode_stub` 9216.9 ALM / 268 M10K)  
- Fit: `w-fit-integ/.../remote_out/fit-t7b-prog480/Plex.fit.rpt`  
- `ddr_frame_store.sv:27` / `mailbox_abi_spec.hpp` doorbell-relative  
- r-misterfin: no userspace applied-HDMI read API  
- Host gap: `bank_cellH=32` vs `hdmi1080_cellH=64`
