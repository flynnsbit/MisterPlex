# T7b RBF `8fdf440f` — source settle (unique rows + chain + pre-reg)

**Deployed artifact (parent):** RBF md5 **`8fdf440fbf4b8b51f5f98df559cc20e5`** (short `8fdf440f`).  
**Freeze tree (not tip, not c5382bee, not 78eff44e):**  
`/home/flynnsbit/mplex-builds/fit-t7b-prog480/Plex_MiSTer/`  
**RBF re-md5 here:** `8fdf440fbf4b8b51f5f98df559cc20e5` · `true rc=0`  
**Fitted `present_core.sv` md5:** `9e6f42ddd1d4a17d65de2edb6777013d`  
**Fitted `ddr_frame_store.sv` md5:** `6c39218e83f30a888841b3e1e0e94d6d`  
**Evidence:** `.agent-work/w-fit-1/FIT_EVIDENCE_T7b.md`  
**QSF:** `FRAME_W=640` `FRAME_H=480` (`Plex.qsf:83-84`)  
**Agent:** source only · no device · no fit.

Tip `present_core` md5 `9a5a9b26…` and c5382bee LE3 `775c12f7…` and 78eff `9c100fba…` are **other** trees — not cited below except as contrast.

---

## 1. Quoted Y-map from **this** freeze only

There are **no** `V_STORE_SD` / `V_STORE_PROG` symbols in T7b. Single product height:

```systemverilog
// fit-t7b-prog480/.../present_core.sv:134-215  md5 9e6f42dd
// Product core timing is always 480 active lines (VBlank @ vc==480).
localparam bit PRODUCT_V_480 = 1'b1;
wire _unused_scandouble_port = scandouble;

colorbars bars (
    ...
    .scandouble(PRODUCT_V_480),   // :148 — NOT forced_scandoubler / cfg[4]
    ...
    .vc_out(vc),
);

localparam H_DE    = 10'd529;
localparam int V_STORE = FRAME_H; // product: full store height (480), both arms
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE; // → 65536 = 1.0 Q16

wire [9:0] py = vc;                                    // :190 — never vc>>1
wire [9:0] v_store = 10'(V_STORE);
wire in_content = (hc < H_DE) && (py < v_store) && ~hb && ~vb;

wire [9:0] store_y_clamped = past_last_row ? (v_store - 10'd1) : py;
// *** T7b: constant 1.0 Q16 — this assignment is what stops store_y doubling ***
wire [31:0] store_y_scale = 32'(STORE_Y_SCALE);        // :211
wire [31:0] store_y_prod = store_y_clamped * store_y_scale;
wire [15:0] store_y_comb = store_y_prod[31:16];
// store_y_addr ← store_y_comb clamped to FRAME_LAST_Y
// reg store_y <= store_y_addr on ce_pix
```

With **FRAME_H=480** (QSF macro → `Plex.sv` `localparam FRAME_H = \`FRAME_H`):

| Symbol | Value on `8fdf440f` |
|--------|---------------------|
| `V_STORE` | **480** (`= FRAME_H`) |
| `STORE_Y_SCALE` / `store_y_scale` | **65536 = 1.0 Q16** (constant; no scandouble mux) |
| `py` | **`vc`** |
| `store_y` | **`py` at 1:1** = **`vc`** for vc∈[0,479] |

`colorbars` with `scandouble=1'b1` (PRODUCT_V_480): NTSC VBlank at `vc==480` → **480** active lines (`colorbars.sv` VBlank branch).  
`scandouble` **port from Plex** (cfg[4]) is **intentionally unused** for DE/store (`_unused_scandouble_port`).

---

## 2. Distinct store rows on progressive path — **480**

**Question:** progressive (`scandouble=0` / cfg[4]=0) — 240 or 480 unique store rows?

**Answer from this freeze: 480.**

Reason: product **ignores** cfg[4] for vertical map. DE is hard-wired 480-line (`PRODUCT_V_480`). Fetch is `store_y = vc` for `vc = 0..479` with scale 1.0 → **480 distinct `rd_y` values** into `ddr_frame_store`.

**Finest resolvable vertical period on glass (luma, before ascal):**  
**1 store row** (period-1 black/white can both be fetched).  
After MiSTer **ascal → 1080p** (framework, not this core), each store row spans ≈ `1080/480 = 2.25` HDMI lines → finest **stable** identical-run on a 1080 capture is **~2–3 rows**, not 1, unless measuring pre-ascal.

Contrast **78eff44e** (`9c100fba`): cfg[4]=0 → `V_STORE_PROG=240` + scale 2.0 → **240** unique (even-only). T7b removed that arm.

---

## 3. Full chain — every ×2 / ÷2

Decoded luma path (product DDR), freeze + host layout contract:

| Stage | What happens | ×2 / ÷2? |
|-------|----------------|----------|
| **ARM write** | I420 into bank: Y `624×480`, stride 624; U/V `312×240` (`ddr_frame_layout.hpp` / `ddr_frame_layout_params.svh`: `CODED_H=480`, `Y_PLANE`, `U/V` half height) | **Chroma only:** UV height ÷2 (4:2:0). **Y: no half.** |
| **DDR phys** | bank0 `0x30000000`, bank1 +`0x80000`; Y row `y * 624` | no V ×2 |
| **Doorbell** | PLXK @ `0x300FF000` | — |
| **`ddr_frame_store` fill Y** | `fill_y` = scheduled **full** line index; `y_addr = base + fill_y * Y_LINE_QWORDS` | **Y 1:1** |
| **`ddr_frame_store` fill UV** | `fill_cy` / `rd_cy = src_y_line[H:1]` (`:343` product, not `FAULT_CHROMA_VERTICAL_FULLRES`) | **Chroma ÷2 vertical** (correct 4:2:0) |
| **`present_core` → `rd_y`** | `store_y` = `py` × **1.0** = `vc` | **T7b removed ×2** (was PROG scale 2.0 / even-only) |
| **`ddr_frame_store` sample Y** | `src_y_line = display_y + CROP_TOP` (`CROP_TOP=0`, `PRESENT_Y=0`); `pref_y` matches `y_line` full res | **Y 1:1** |
| **H map** | `store_x ≈ hc * STORE_X_SCALE>>16` over H_DE=529 → presented X (640 class) | horizontal only; not V half |
| **ascal (sys_top)** | core ~480 DE → HDMI 1080 | **upscale ~2.25×** (external; adds run-length, does not drop store rows) |

**Two halvings?**  
Historically: (1) **PROG `store_y=py*2` / 240 DE** (present_core) + (2) **optional** chroma `y>>1` (correct).  
T7b removes **(1)** only. **(2) remains for U/V** and must stay — it does **not** limit **Y** unique rows.

**No second present-side luma half found** in this freeze after T7b.

---

## 4. Pre-registration (glass) for parent stripe fixture

**Assumptions (state them):**  
- RBF **`8fdf440f`** freeze above.  
- Fixture: full-bleed **luma** 1-row B/W + zones period **2/4/8/16** (+ chirp), coded into **624×480** Y (content in active present window).  
- Capture **1920×1080** after ascal; content scaled to fill ~1080 active (parent 1:1 capture of HDMI).  
- Scale model: `hdmi_run ≈ store_period × (1080/480) = store_period × 2.25` (ascal geometry; not exact filter phase).

| Zone (store period) | Predict on **8fdf440f** (Y path fixed) | Falsify (still 240-class) |
|---------------------|----------------------------------------|---------------------------|
| **P1** 1-row B/W | Both phases present; mean identical-row run on 1080 ≈ **2.0–3.0** (target **2.25**); **not** solid field; even/odd **store** phases both visible after accounting for 2.25× | Solid / invert-on-phase / mean run **≈4.0–5.0** (240→1080 ≈4.5) or B2-style opposite solids |
| **P2** | mean run ≈ **4.5** (band 4–5) | mean run ≈ **9** |
| **P4** | mean run ≈ **9** (8–10) | ≈ **18** |
| **P8** | mean run ≈ **18** (16–20) | ≈ **36** |
| **P16** | mean run ≈ **36** (32–40) | ≈ **72** |
| **Chirp** | modulation visible down to ~period 1–2 store | floor stops near period ~2 store (maps ~4.5 HDMI) as if 240 unique |

**Idle logo / flat RK6:** UNSCORED for this claim (parent already proved) — do not use for D3.

**Coverage note:** this document is **source settle**, not a sim gate. No `rc=0` claimed over empty TB set.

---

## 5. `p_d1` derivation — correct or retract user wording

**Source:** `host/libmisterplex/publish_swap_delta_ledger.hpp` (tip; metric math is host-side).

| Field | Derivation (file:line intent) |
|-------|-------------------------------|
| **`p_d1` / `p_delta1`** | Fraction of consecutive **publish notes** with `unwrap(Δ frames_done)==1`, where `frames_done` is sampled from **PLXD[63:48]** at publish. Header: `p_delta1_der=frac(delta_frames_done==1)_NOT_hold`. Alias: `p_d1_is=delta_frames_done_eq1_NOT_hold_refresh`. |
| **`p_hold_d1`** | Fraction of publish intervals with `hold_d = round(iv_ms / T_vsync) == 1`. **This** is “held for one refresh.” |

**Parent sentence to user:**  
“`p_d1=0.0335` ⇒ ~3.4% of frames held one refresh ≈ one hitch/s”  

**Verdict: MISNAMED — retract that mapping.**

- On **swap-counter** RBF (`8fdf440f` / `78eff44e` pack `frames_done_d2` at store `:1043`), **Δfd=1 is the normal one-swap-per-publish case** → healthy series should show **`p_d1 ≈ 1.0`**, not 0.03.  
- Parent soak shape `p_d1=0.0335` + `p_dge2=0.9639` is **not** a hold histogram; treating it as hitch rate was the field-name defect.  
- **Replacement wording (only after tip daemon emits it):**  
  “`p_hold_d1` = fraction of publish intervals with `round(interval_ms / T_vsync)==1` (derivation hold_d; vsync_hz often ESTIMATE_60Hz).”

Cadence mechanism (unchanged): no min-2 interlock → 1-refresh hold RTL-legal; 907e ≠ early-hold cause.

---

## Bottom line

| Item | Result |
|------|--------|
| Unique Y store rows on product path (`8fdf440f`) | **480** (cfg[4]-independent) |
| T7b goal (stop PROG ×2) | **Achieved in this freeze source** |
| Glass D3 | Still needs stripe fixture; source predicts period-1 survives at ~2.25 HDMI runs |
| Second luma half | **Not found** post-T7b; chroma ÷2 only |
| `p_d1` as hitch % | **Wrong — retract** |

**Identification:** RBF md5 match to `fit-t7b-prog480/output_files/Plex.rbf` + FIT_EVIDENCE_T7b.md.
