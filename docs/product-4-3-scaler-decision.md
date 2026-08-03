# Product 4/3 scaler decision (w-scaler)

**Commit:** `6deb5af7` `present_scale_4_3.sv` · tip follow-ups on branch `w-scaler-window`  
**Path:** PMS **960×540** → ARM 34.50 ms (margin **+7.16**) → fabric **1280×720 OUTPUT**

## 1. Exact 4/3 — specialised (not general bilinear)

| | General `present_content_window` | Product `present_scale_4_3` |
|--|----------------------------------|-----------------------------|
| Map | Q16 `ceil((cw-1)·65536/(de-1))` × hc | `src = dst·3/4` integer |
| Phase | free-running frac from mul residue | **4 fixed phases** `(3·dst)mod4` = `x_num[1:0]` → **0,3,2,1** (NOT `dst[1:0]`) |
| Weights | runtime frac | **4-entry ROM** 0,¼,½,¾ |
| Pixel arith | 11×20 mul + >>16 | `*3` + `>>2` |
| Divider | on reg update | **none** |
| Use | PMS 720×404, arbitrary PLXG | **ship 960×540 only** |

**Resource delta (pre-fit estimate, honest):**
- ALM: 4/3 **cheaper** (~50–150 ALM less when it replaces a general instance on the product path)
- M10K address path: **both 0**
- DSP: both 0 (lerp optional small)
- Fmax @29.7 MHz clk_pix: both OK; 4/3 easier (no 20b mul on ce_pix)

Endpoints of both families agree within 1 px (`test_scale_4_3_vs_general`).  
Gate: `tests/unit/test_present_scale_4_3_rtl_sim.sh` (RED invert + phase_obo).

## 2. Vertical taps — **ship 2-tap**

| | Lines held (source 960 B) | M10K budget | Quality |
|--|--------------------------:|------------:|---------|
| **2-tap biline V** | 2 | **2** | Soft; possible residual line-twitter on hi-contrast motion |
| 4-tap V | 4 | **4** | Better twitter control |

Free M10K post-nostub: **356**. Area is not the constraint — **wiring complexity** into present_core before w-clock’s real `clk_pix` PLL is.  
**Decision:** ship **2-tap**. Enable `PRESENT_SCALE_4_3_VTAPS4` only if parent glass shows twitter.

## 3. Four-lane geometry freeze

| Role | Value | Owner |
|------|------:|-------|
| Source content | **960×540** | PMS / ARM publish |
| Product bank stride | **960** | w-mem WRITE / w-scaler READ |
| Product bank bytes | **777600** | I420 |
| STORAGE vs CANVAS | Storage **960×540/777600** drives plane bases; canvas **1280×720** is DE only. Conflating → U=921600 vs 518400. | rd-duck; `DdrNativeContentLayout` |
| Option-C bank map | **w-mem owns** usable-capacity select (`stride-0x1000`). w-scaler READ uses `eff_*` only. | w-mem |
| Phase index | `phase=(3·dst) mod 4` → **0,3,2,1** via `x_num[1:0]`. NOT `dst[1:0]`. | rd-duck; oracle test |
| SPS coded H | 544 ring/decoder only; product bank = 540 after FFmpeg crop. | parent SPS + rawvideo wc |
| Glass DE | **1280×720** | w-clock `PRESENT_MULTI_PIXEL` |
| HUD canvas | **1280×720** | w-osd `kTargetOut` |
| Scale | exact **4/3** | w-scaler `present_scale_4_3` |
| clk_pix | **≈29.7 MHz** for 720p24 CEA | w-clock PLL (grant blocked until real) |

Macros default **OFF** — bit-identical to control at reset.

## Parent verify

```bash
tests/unit/test_present_scale_4_3_rtl_sim.sh; echo s43=$?
./build/test_scale_4_3_vs_general; echo cmp=$?
./build/test_720p_geometry_lane_agree; echo geom=$?
```

## 2-PPC pixel engine (rd-duck load-bearing)

`present_scale_4_3.sv` is the single-pixel **mapper** (coords + sum-256 weights).
`present_scale_4_3_2ppc.sv` is the **pixel path**: dual-dst group, up to 3 H taps × 2 V
lines, bilin with `(·+128)>>8`.

Weights sum **256** (phase0 was 255+0 — constant color lost LSBs). ROM:
`(256,0),(192,64),(128,128),(64,192)`.

Default OFF. Not wired into `present_core` / `ddr_frame_store` until w-clock 2-PPC
bridge + w-mem storage/canvas split. Fit remains NN/off.

Registered: `test_present_scale_4_3_*` host + `test_present_scale_4_3_rtl_sim.sh` +
`test_present_scale_4_3_2ppc_rtl_sim.sh` (const + ramp max_abs=0 + RED PHASE_DST).

## Pipeline / component (rd-duck fit path)

- **Plane = Y (luma)**. Not RGB. U/V half-res later (or NN chroma v1).
- **Comb `req_*`** drives M10K `rd_addr` same cycle as `hc_g/py`.
- **`RAM_LAT=1`**: meta (phase/weights/ix/DE) delayed to meet `rd_data` taps.
- Registered `tap_base_x/store_*` are diagnostics only — never same-cycle RAM addr.
- Still default-OFF until dual-line Y provider wired through `ddr_frame_store`.

## ascal near-term fork (rd-duck challenge) — verdict for parent

**Question:** Can the core emit a **true** 960×540 DE at ≤20 MHz / ~24 Hz and let
sys_top `ascal` (`iauto=1`) do 960→1280×720 HDMI, deferring custom 4/3 + 2-PPC +
29.7 MHz clk_pix?

### Source facts (not inference)

| Fact | Where |
|------|--------|
| `ascal` already on HDMI; **`iauto=1`** autodetects input image from `i_de` | `sys_top.v:758` `.iauto(1)`; `ascal.vhd` iauto comment |
| Output raster = HPS `WIDTH`/`HEIGHT` (ship 1280×720 class) | `sys_top.v` `hdisp(WIDTH)` / `vdisp(HEIGHT)` |
| Dead end was **island-in-large-DE** (pad + full-bank sample) → quarter glass | design mandate / `docs/fabric-content-window-rtl.md` pad-only row; **not** true content DE |
| `H_DE=640` **impossible** at **clk_sys=20 MHz / 60 Hz / 524 lines** (max H_total=636) | `present_core.sv:194-196`, `test_present_store_scale_math.cpp:160-166` |
| That forbid is **60 Hz + ~524-line** class — it does **not** by itself forbid 960-wide at **~24 Hz** with a longer line period | same arithmetic: `20e6/24/600 ≈ 1389` clocks/line > 960+blank |
| Product Template FBAR lock is **H_DE=529** | `present_core.sv:204`, lane contract |
| Custom path needs **1280×720 core DE @ ~29.7 MHz** (w-clock PLL still placeholder) | lane contract; parent fit HOLD on PLL |
| Active rate 960×540×24 ≈ **12.4 Mpix/s** vs 1280×720×24 ≈ **22.1 Mpix/s** | arithmetic |

### Verdict

**No source-backed hard forbid of the ascal near-term path** for ship 960×540→720p
HDMI **if and only if**:

1. Core DE is **exactly content-sized** 960×540 (not a 960 island inside 529/1280 DE).
2. Beam/timing is a **new class** (w-clock): ~24 Hz capable line totals on clk_sys —
   **not** the 60 Hz / 524-line Template that caps H_total at 636.
3. Lab accepts FBAR/Template 529 instruments **do not** apply to this mode (or are
   retargeted). That is process/lab, not silicon forbidding ascal.

**What ascal path buys now:** drops custom 2-PPC/Y-tap provider + core 29.7 CDC from
the **near-term fit critical path**; reuses already-paid ascal polyphase (~2.9k ALM);
ARM still publishes **960×540 / 777600** only.

**What it does not buy:** identity core DE for HUD/chrome alignment experiments that
assume 1280×720 pre-ascal; exact 4/3 phase control in-core; removing ascal later.

**Keep w-scaler 4/3 + 2ppc as upgrade/fallback** (default-OFF): when w-clock real
`clk_pix` lands and dual-line Y is wired, core can emit native 720p DE and ascal
becomes near-identity (`docs/fabric-content-window-rtl.md`: ascal does not re-filter
when DE equals output raster).

**Unknown until parent measures (not claimed):** ascal lock on 960×540@~24→HDMI@60
cadence, VS relationship, first-frame black. Check = one menu with true 960×540 DE
timing + HDMI capture MEAN/ACTIVE — parent-owned.

### Pre-registered numbers (ascal-path feasibility arithmetic)

| Quantity | Value |
|----------|------:|
| clk_sys | 20_000_000 |
| max H_total @60 Hz / 524 lines | 636 |
| clocks/frame @24 Hz | 833_333 |
| 960×540 active pix/frame | 518_400 |
| min clocks/frame if 1 clk/pix active | 518_400 (+ blanking) |
| 1280×720×24 Mpix/s | 22.118 |
| 960×540×24 Mpix/s | 12.441 |

## Exact 2× tier under the **ascal pivot** (parent ask)

### Recommendation for near-term fit

**Do not wire in-core exact-2× into the ascal near-term fit.**  
True **640×360 DE** + sys_top `ascal iauto=1` already performs 640→1280 / 360→720.
Building a second doubler on that path earns **nothing on glass** for B4.

| Path | Near-term ascal fit | Later upgrade (pre-ascal 1280 canvas / HUD) |
|------|---------------------|-----------------------------------------------|
| 960×540@24/30 | true DE → ascal | `present_scale_4_3` (+2ppc) default-OFF |
| 640×360@30 | true DE → ascal | `present_scale_2x` default-OFF (already on branch) |

**Why keep `present_scale_2x` at all (upgrade only):**
1. Forced NN replication (ascal polyphase softens; 2× has no phase ROM to mis-index).
2. 0 mul on pixel path vs Q16 general.
3. Explicit tier select when core emits native 720 DE later.

**Why it does not earn a near-term seat:** ascal already paid (~2.9k ALM); true content
DE is the load-bearing constraint, not the scaler algebra.

Module + RBG remain on branch (`d7084b18`, `test_present_scale_2x_rtl_sim.sh`) —
**default-OFF, not cancelled, not fit-critical.**

### SETTLED: why `max_diff=1` hid the 4/3 phase bug

**Finding (not hypothesis):** general path does **not** share the defect.  
Evidence: `35927575` / `./build/test_scale_4_3_vs_general` — pred_hit=P11/P21/P31/P41.

| # | Claim | Observation that would falsify it |
|---|--------|-----------------------------------|
| P1 | General frac = Q16 `prod[15:8]`, not `dst mod 4` | frac@hc1 near 64 (dst-bug) instead of ~192 |
| P2 | Old vs_general was **floor-only** | floor max_diff would move when phase ROM swaps |
| P3 | Unit ramp hides phase bug at ≤1 LSB | unit-ramp \|oracle−bug\| ≥ 64 |
| P4 | Not “both paths wrong” | general closer to oracle than dst-mod4 on hi-contrast |

Measured (host rerun): `floor_max_diff=1`, `unit_ramp_phase_bug_max=1`,
`hi_contrast_phase_bug_max=127`, `frac1=191`, `bug_vs_or_hi_max=127`.  
→ **We fixed one specialised-path bug; general Q16 bilin is a different (OK) class.**

## True 960×540 (or 640×360) DE — integrator contract

**Ballgame:** ascal `iauto=1` sets `i_hsize/i_vsize` from **i_de** edges
(`ascal.vhd` iauto path; `sys_top.v` `.iauto(1)`).  
If DE is larger than content, ascal upscales the **whole DE** (pad included).

### present_core → sys_top boundary (checkable)

| # | Requirement | How to verify |
|---|-------------|----------------|
| 1 | DE width (cycles with DE=1 per active line) **== content_w** | count `~HBlank` run; ≠529 Template, ≠1280 canvas |
| 2 | DE height (lines with any DE=1) **== content_h** | count lines; 540 film / 360 TV |
| 3 | Every DE=1 sample is **content** (no black pad inside DE) | content_on_de == de_pixels |
| 4 | Store map **identity** inside DE: `store_x==hc`, `store_y==py` | not `floor(hc*cw/H_DE_large)` |
| 5 | Runtime `win_h_de` / beam H_DE **== content_w** | mailbox/PLXG storage dims, not glass canvas |
| 6 | ascal-measured ihsize/ivsize **== content_w/h** | follows from 1–2 when iauto=1 |

**True:** DE rectangle ≡ content rectangle.  
**Forbidden island examples:**
- 320×240 paint inside Template **529×480** DE (classic quarter-glass)
- **960×540** paint inside **1280×720** core DE (canvas/storage conflation)
- Claiming 960-wide content while `H_DE` left at **529**

### Automated gates (no device)

**Config-space contract** (parameter legality):
```bash
tests/unit/test_true_content_de_contract.sh   # product + RED FAULT_ISLAND_PASSES
```

**Counted RTL raster** (elaborated beam + window + DE_LAG — load-bearing for fit):
```bash
tests/unit/test_present_true_de_count_rtl_sim.sh
# PRODUCT: true_de=1 de_w=960 de_lines=540 de_pixels=518400
#          H_TOT=1182 V_TOT=564 fps@20M=30.0008 store_id_ok=1
# RED PRESENT_BEAM_FAULT_ISLAND_1280: de=1280x720 true_de=0 rc≠0 + EXECUTED
```

**Fit card (w-nostub drop-in):** `docs/ascal-true-de-fit-card.md`  
Macros: `PRESENT_BEAM_960`; runtime `win_enable=1`, `content_w/h=960/540`, `win_h_de/v_de=960/540`.
### Cadence note (24 vs 30 → HDMI 60) — source-backed, limited claim

ascal has a **DDR framebuffer** (`vbuf_*` on `ascal` in `sys_top.v`); `i_clk`/`i_ce`
are independent of `o_clk` (hdmi). So ascal **does** decouple core frame rate from
HDMI line rate: input frames are written, output scans at 60.

**What that does *not* remove:** display **repeat pattern** on glass.
- 24→60 = **5:2** (some frames shown 2×, some 3×) → film judder class
- 30→60 = **2:1** (every frame shown twice) → no 3:2-style cadence

Whether that is acceptable is product taste + parent capture — not a silicon forbid.
**Budget:** 960×540×30 ≈ 15.55 Mpix/s is inside w-clock’s 40 Mpix/s bridge; prefer
**30** when PMS/ARM margin allows if judder is the concern. Unknown until measured:
ascal first-frame lock on 960×540@30 — parent HDMI check.
