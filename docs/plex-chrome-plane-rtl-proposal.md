# RTL proposal: `plex_chrome` — output-resolution overlay plane

**Owner:** w-osd-hires · **Status:** design only — **no Quartus fit**  
**Tip context:** `bc3d3484` (ARM bank chrome + fail-closed `plane=1` scaffolding)  
**Strategic drivers (parent):**
1. User bug #2 — HUD must match **applied** MiSTer output res, not content/bank.  
2. User direction — **offload ARM** to fabric/BRAM/DDR.  
**One plane serves both:** post-ascal composite + semantic list (ARM stops per-frame pixel bake).

**Binding device budget (parent, current fit class):**

| Resource | Used / Total | Free |
|----------|-------------:|-----:|
| ALM | 23,585 / 41,910 | **18,325** |
| M10K | 465 / 553 | **88** |
| DSP | 44 / 112 | **68** |

`decode_stub` reclaim (w-fit-1): **~9,217 ALM + 268 M10K** if stub never presents after `host_owns_fs` (`Plex.sv:682-692`).  
Post-reclaim free M10K ≈ **88+268 = 356** (order-of-magnitude; map before spending).

---

## 0. Decisive finding (restated)

| Path | Can fix user bug #2? |
|------|----------------------|
| ARM composite into F1 624×480 | **No** — stretched by `present_core`+ascal |
| Framework `sys/osd.v` | **No** — 256×64, Main SPI, dead during play |
| **Post-ascal `plex_chrome` on `clk_hdmi`** | **Yes** — 1:1 output pixels |

ARM-only ship = bank sharpness only. Full fix = this RTL + ARM list writer.

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

### Proposed insertion (framework-legal)

```text
ascal → shadowmask → [plex_chrome NEW] → osd hdmi_osd → HDMI
                         ↑
              clk_hdmi, din/hs/vs/de
              optional: hdmi_width/height
```

**Why after shadowmask, before `osd`:**
- Same stage class as framework OSD (proven composite after ascal).
- F12 menu stays on top of player chrome (correct z-order).
- Does not touch `present_core` / F1 / bank timing (w-geom scaler lives elsewhere).

**If post-ascal were blocked** (it is **not** — `osd` already sits there):  
best alternative would be pre-ascal DE blend → quality ceiling = core DE (~529×240-class), **fails user requirement**. Not proposed.

### Clock / CDC

| Domain | Role |
|--------|------|
| `clk_hdmi` | Pixel counters, glyph expand, RGB blend (hot path) |
| `clk_sys` | List mailbox write port, font ROM load if any, control regs |
| CDC | Dual-clock RAM for list (sys write / hdmi read) or shadow regs on vs |

Pattern already used by `osd.v`: `clk_sys` fills buffer; `clk_video` reads + blends.

### Geometry authority (applied timing, not ini intent)

`sys_top.v:896-910` already maintains:

```verilog
hdmi_height <= (VSET && (VSET < HEIGHT)) ? VSET : HEIGHT;
hdmi_width  <= (HSET && (HSET < WIDTH))  ? HSET << HDMI_PR : WIDTH << HDMI_PR;
```

**Scanout must use DE pixel counters** (like `osd.v` `dsp_width`) and/or these wires — **never** ARM-supplied WxH alone.

**ARM discovery of applied timing (v1 → v2):**

| Source | Role |
|--------|------|
| `MiSTer.ini` `video_mode` | Layout **preview** only (`mister_video_mode.hpp`) — intent |
| **New** PLXO status qword (FPGA→ARM) | **Applied** `hdmi_width/height` + feature bit — **consume r-misterfin** for final packing; do not invent a second research path |
| Fail closed | If PLXO absent → `plane=0` bank chrome (today) |

---

## 2. Storage options — M10K cost

Full-frame BRAM is impossible: 1920×1080 RGB565 ≈ **1620+ M10K** ≫ 88.

| Option | What ARM writes | Fabric storage | Est. M10K | ARM CPU | Sharp @ output? |
|--------|-----------------|----------------|----------:|---------|-----------------|
| **A. Semantic display list + font/icon ROM** (primary) | cmds only | ROM + 2× list RAM | **14–24** | event-driven ≪1 ms | **Yes** |
| **B. ARM-written BRAM band** (bottom panel RGB565) | pixels each UI | 2× band (e.g. 1920×160×16) | **~96–120** | paint band | Yes | **Does not fit 88** |
| **C. DDR panel strip + line FIFO** | pixels to DDR | 2–4 line FIFO + FSM | **4–8** (+DDR port) | paint DDR | Yes | Contends F1 DDRAM |

### Option A detail (fits **88 free**)

| Block | Contents | M10K |
|-------|----------|-----:|
| Font 12×16 ×96 ×1bpp | 18 432 bit | 2 |
| Font 8×13 ×96 ×1bpp | ~10 kbit | 1 |
| Icons 8×32×32×1bpp | 8 kbit | 1 |
| List RAM double-buf 2×512×64b | 64 kbit | 8 |
| Optional y-span index | | 0–4 |
| **Total A** | | **12–16** (budget **≤24** w/ packing) |

### Option B — needs stub reclaim

1920 × 160 × 16 bit × 2 buffers ≈ 1.23 Mbit ≈ **120 M10K** → **blocked** until stub reclaim (~356 free). Mark **Inc-B dependent on w-fit-1 stub out**.

### Option C — escape hatch

Only if list cannot express future art. Second DDR reader on active video is higher risk; **not first fit**.

**Primary ship path = A.** Inc-1 can be HW solid rect only (**0 M10K**) to prove post-ascal blend before ROM.

---

## 3. ARM interface — semantic, doorbell-relative

### Principle

ARM sends **meaning** (state, progress, strings as glyph codes, icon ids, geometry in output px).  
RTL expands to pixels on `clk_hdmi`. That **removes** `renderYuv420p` bake from the play loop when `plane=1`.

### Address map (MUST be doorbell-relative)

Reuse lesson: **never hardcode absolute phys**; always `DOORBELL_PHYS + offset`  
(`mailbox_abi_spec.hpp`, `BANK_MAILBOX_PHYS = DOORBELL_PHYS + 0x128`).

| Offset | Tag | Dir | Purpose |
|-------:|-----|------|---------|
| +0x128 | PLXD | F→A | bank (existing) |
| **+0x130** | **PLXC** | A→F | chrome list control / doorbell |
| **+0x138** | **PLXO** | F→A | applied `width/height` + `chrome_hw=1` + gen |
| +0x140 | PLXL0 | A→F | list buffer phys base / or inline if small |

*(Exact packing: add to `mailbox_abi_spec.hpp` + `test_rtl_invariants.py` before RTL merge.)*

### PLXC control word (illustrative 64-bit)

```text
[31:0]  magic 'PLXC'
[32]    enable
[33]    bank_sel          // which list buffer is live
[47:34] cmd_count         // 0..512
[63:48] seq               // monotonic; fabric latches on vs after seq change
```

### Command ISA (64-bit, ≤512 cmds)

| op | Fields |
|----|--------|
| `RECT` | x,y,w,h, rgba8 — panel / bar track / fill |
| `GLYPH` | x,y, code, font_id, scale 1..8, rgba8 |
| `ICON` | x,y, id, scale, rgba8 |
| `BAR` | x,y,w,h, fill_w (ARM-precomputed → **0 DSP**) |
| `END` | — |

Pause chrome ≪ 64 cmds. ARM builds on **UI event only** (pause/play/seek/notice), not every video frame.

### Feature enable (fail closed)

```text
chromePlaneLive = CHROME_PLANE conf ∧ PLXO.chrome_hw
```

Already scaffolded: `MediaPlayer::chromePlaneLive()`, skip F1 bake when live.

---

## 4. Scaling rule (acceptance = existing gate)

```text
outW,outH = applied (PLXO or DE) — not DECODE, not bank
L = computeOutputChromeLayout(outW, outH)   // mister_video_mode.hpp
  bodyScale = half-to-even round(H/240) clamp 2..8
  font = H>=480 ? 12×16 : 8×13
  panelH from fractions; snap even; clamp in-bounds
```

| Mode | H | bodyScale | cellH (gate) |
|------|--:|----------:|-------------:|
| 240p | 240 | 2 | 26 |
| 640×480 | 480 | 2 | 32 |
| 800×600 | 600 | 2 | 32 |
| 1080p | 1080 | 4 | 64 |
| 1440p | 1440 | 6 | 96 |

**Host acceptance (already green):**  
`test_overlay_crispness_mutation` — `bank_cellH=32` vs `hdmi1080_cellH=64`; inkH tracks cellH on output layouts.

**Glass acceptance (parent):** stem edge ≤2 grabber px @ mode 12; L:R chrome not required; advance ≈ 13×bodyScale ±10%; not soft bank stretch.

---

## 5. Budget versions

### V1 — fits **88 M10K free** (no stub dependency)

| Item | Pred. Δ |
|------|--------:|
| M10K | **+16..24** (leave ≥64 free) |
| ALM | **+1.5k..4k** |
| DSP | **0** (ARM bar fill_w) |
| Fmax | close existing HDMI path; ≤32 active cmds/line, 2–3 stage blend |

**Hard fail if map shows:** M10K Δ > 40, ALM Δ > 6k, or negative HDMI slack.

### V2 — after `decode_stub` reclaim (w-fit-1)

| Add-on | Pred. Δ extra |
|--------|--------------:|
| Optional BRAM panel band (opt B) | +80..120 M10K |
| Or richer icon ROM / anti-alias 2bpp fonts | +4..12 M10K |
| Combined free after stub | ~356 M10K class |

V2 **not** required for user bug #2 text/icons. Mark **dependent on stub reclaim map**.

### Inc-1 (optional first silicon slice)

Solid-color bottom rect + enable bit only: **~0 M10K, ~0.3–0.8k ALM**. Proves post-ascal blend + PLXC enable before font ROM. Can share fit with V1 if schedule prefers one shot.

---

## 6. Combined ONE-fit request (coordinate)

**Do not schedule three exclusive fits.** Single coherent grant:

| Lane | Deliverable in same RBF |
|------|-------------------------|
| **w-fit-1** | `decode_stub` reclaim (funds M10K/ALM) + chrome feature bit / PLXO wire-up |
| **w-geom** | content window + fabric scaler in `present_core` (delete ARM 320→618 resample) — **pre-ascal / F1 path** |
| **w-osd-hires** | `plex_chrome` V1 post-ascal list blender + ARM list writer / `plane=1` |

**Dependency order inside one compile tree:**
1. Stub reclaim (area).  
2. w-geom scaler (video path; independent of chrome pixels).  
3. `plex_chrome` insert in `sys_top` between mask and `osd`.  
4. Mailbox ABI + invariants gate green **before** merge.

**Pre-registration (combined — update when peers publish numbers):**

| Resource | Baseline | Pred. Δ chrome V1 | Pred. Δ geom (TBD peer) | Pred. Δ stub reclaim | Net free M10K target |
|----------|----------|-------------------:|------------------------:|---------------------:|---------------------:|
| M10K | 465/553 | +20 | peer | −268 used | ≫ 88 |
| ALM | 23585/41910 | +3k | peer | −9k used | healthy |
| DSP | 44/112 | +0 | peer | 0 | — |
| Timing | existing | HDMI path must HOLD | present_core path | — | no neg slack |

Chrome owner prereg for **chrome slice alone:**  
**M10K +20 ±4 · ALM +3000 ±1500 · DSP 0 · HDMI Fmax hold.**

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
| G2 Verilator | `plex_chrome` + font ROM, 1 line of PAUSED at 640 and 1920 | sim |
| G3 solo map | hierarchical synth M10K≤40 ALM≤6k | **before** fit grant |
| G4 glass | parent pause grab edge sharpness | after ONE fit |

---

## 9. Explicit non-goals

- Replacing framework F12 `osd.v`  
- Full-frame BRAM or full-frame DDR overlay in V1  
- Claiming bug #2 shipped on bank ARM path  
- Mid-fit source edits  

---

## 10. Recommendation (one paragraph)

**Fund post-ascal `plex_chrome` V1 (display-list + font/icon ROM, ≤24 M10K, 0 DSP, ~2–4k ALM)** inserted at `sys_top.v` between shadowmask and `hdmi_osd`, clocked on `clk_hdmi`, geometry from DE/`hdmi_width/height`, control via **doorbell-relative PLXC/PLXO**. ARM emits semantic lists only; product play path stops F1 chrome bake when HW bit live. Land in **one** exclusive fit with w-fit-1 stub reclaim + w-geom scaler. Option B BRAM band only after stub reclaim. Until then, bank 624×480 chrome remains the fail-closed path — **useful, not the user-bug fix.**

---

## 11. References

- `sys_top.v:714-768` ascal · `:1159-1200` mask+osd · `:896-910` hdmi_width/height  
- `sys/osd.v:26-36` 256×64 buffer (stage right, capacity wrong)  
- `Plex.sv:682-692` `host_owns_fs` / stub never product-present  
- `ddr_frame_store.sv:27` `BANK_MAILBOX_PHYS = DOORBELL_PHYS + 0x128`  
- `mailbox_abi_spec.hpp` relative offsets  
- `docs/osd-chrome-plane-design.md` prior paper (superseded for funding by this doc)  
- `docs/osd-native-raster-arm-design.md` ARM half  
- Host gap gate: `bank_cellH=32` vs `hdmi1080_cellH=64`
