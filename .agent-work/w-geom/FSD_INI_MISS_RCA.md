# forced_scandoubler=1 INI experiment MISS — source RCA

**Artifact pair for parent experiment (caller-supplied):**  
RBF **`78eff44ed32c7ce35d648e3da5e2b93f`** + daemon **`7c991e47`** · idle logo · fsd 0→1 → MISS.  
**Freeze tree for all RTL quotes:** `/home/flynnsbit/mplex-builds/fit-ceil-fd/Plex_MiSTer/`  
(`present_core.sv` md5 `9c100fba…`, not tip).  
**Agent:** no device, no fit. Repo commit for this note: see `git rev-parse` after commit.

---

## URGENT FOR w-fit-1 (read first)

**Product HDMI default does not rely on `forced_scandoubler=1`.**  
Even though the SD arm **can** be selected in RTL when `cfg[4]=1`, the **shipping path is progressive (`scandouble=0`)** unless the user sets a MiSTer.ini knob the INI comment itself marks as VGA-oriented.

Therefore the ceiling fix **must make the progressive arm fetch all 480 store rows** (`V_STORE_PROG` / scale when `scandouble=0`), **not** merely leave 480 on the SD arm.

**Do not ship a fit that only fixes `V_STORE_SD`.**  
78eff44e already has `V_STORE_SD=480` + scale 1.0 + `py=vc`; parent’s fsd=1 experiment did **not** unlock a measured resolution win on idle logo, and users will keep `fsd=0`.

Recommended fit shape (for w-fit, not implemented here):  
at product `FRAME_H=480`, **both** arms use `V_STORE=480` and `STORE_Y_SCALE=1.0` with `py=vc` (tip `NATIVE_V_1TO1` form), **or** at minimum `V_STORE_PROG=480` + scale 1.0 when `FRAME_H>=480`.

---

## (a) Does INI `forced_scandoubler` reach the core on HDMI?

### Origin (framework)

`sys/hps_io.sv` (freeze):
```systemverilog
// :197-200
assign buttons = cfg[1:0];
//cfg[2] - vga_scaler handled in sys_top
//cfg[3] - csync handled in sys_top
assign forced_scandoubler = cfg[4];
```
`cfg` loaded from HPS UIO: `'h01: cfg <= io_din` (`hps_io.sv:351`).

`sys_top.v:303`: **separate** `wire forced_scandoubler = cfg[4]` — used **only** for composite subcarrier gate (`:1466`), **not** for ascal/HDMI pixel path.

### Core connection (freeze `Plex.sv`)

```systemverilog
// :133
.forced_scandoubler(forced_scandoubler),   // hps_io output → emu wire
// :741
.scandouble(forced_scandoubler),           // → present_core
```

### HDMI path (does framework scandouble for HDMI?)

```
emu VGA_*  →  scanlines  →  ascal  →  HDMI
```
(`sys_top.v` `VGA_scanlines` then `ascal` `i_*` from `vga_*_sl`).  
**No** `scandoubler` module on the HDMI feed. **No** use of `forced_scandoubler` between emu and ascal.

### Verdict (a)

| Claim | Result |
|-------|--------|
| “Framework never drives core `forced_scandoubler` on HDMI” | **KILLED.** Core gets `hps_io` `cfg[4]` regardless of HDMI vs VGA. |
| “Framework HDMI path ignores INI for *scaling*” | **True but incomplete.** HDMI does not *also* scandouble in sys_top; **resolution arm is entirely the core’s** `present_core.scandouble` ← `cfg[4]`. |
| INI comment “VGA OUTPUT” | Describes Main’s historical intent; **wire still reaches Plex**. Whether Main wrote `cfg[4]=1` on the device is **not proven in this source pass** (would need cfg dump on device). |

**So (a) is not “SD arm unreachable.”** Config *can* select SD in RTL. Experiment MISS is not explained by a missing HDMI wire.

---

## (b) Is `.scandouble(forced_scandoubler)` overridden in the freeze?

**KILLED.**

Freeze-only grep of `scandouble` / `forced_scandoubler` in `Plex.sv` + `present_core.sv`:

- Single present_core bind: `.scandouble(forced_scandoubler)` (`Plex.sv:741`).
- `present_core` uses port `scandouble` for `v_store` / `store_y_scale` and passes it to `colorbars` (`present_core.sv:139,186,205`).
- **No** tie-off to `1'b0`/`1'b1`, **no** second driver, **no** AND with status.

**Note (not a scandouble override):** CONF_STR `O[4]` is **Content resolution** → `status[4]`, **not** `cfg[4]`:

```systemverilog
// Plex.sv CONF_STR
"O[4],Content resolution,320x240,640x480;",
```

Different namespaces: OSD `status[4]` vs video cfg `cfg[4]`. Do not conflate.

---

## (c) Why could metrics move the wrong way if something changed?

### What SD=1 **should** do in this freeze (RTL)

`colorbars.sv` (freeze):
- `scandouble=0`: `ce_pix` toggles; VBlank at `vc==240` (NTSC) → **240** active lines.
- `scandouble=1`: `ce_pix<=1` always; VBlank at `vc==480` → **480** active lines.

`present_core.sv` (freeze, md5 `9c100fba`):
- `scandouble=1`: `v_store=480`, scale **1.0**, `py=vc` → fetch rows **0..479**.
- `scandouble=0`: `v_store=240`, scale **2.0**, `py=vc` → fetch **even** rows only over 240 DE.

If `cfg[4]` truly became 1, the **fetch** arm is the 480-row path. That is source-solid.

### Why idle-logo glass metrics can still MISS / go the wrong way

Parent baseline already:

| metric | fsd=0 |
|--------|-------|
| evenodd_pair_ident | **0.9876** (near ceiling) |
| adj_identical | 0.9055 |

So **before** INI, the instrument already saw almost no even/odd pair difference on **idle logo @ 1080p ascal**. That is a **near-saturated** detector — unlike B2 `push_frame` even/odd solids (std=0 invert on **c5382bee**), which force orthogonal row phases.

Plausible mechanisms consistent with **small wrong-direction** moves (not asserted as sole cause; ranked):

1. **Stimulus class (strongest for MISS vs B2):** Idle logo is soft / low vertical Nyquist. Unlocking odd store rows adds little HF. ascal 480→1080 vs 240→1080 changes filter footprint → `mean_adj_diff` can **fall** (more correlated neighbors) without “more detail.”  
2. **ascal geometry change (real path change even if content HF flat):** Input active height 240→480 changes scale factors into 1080; bilinear/polyphase can reduce adjacent-row Δ. Matches “something changed, less detail.”  
3. **Content already even-only in the store (ARM paint):** If idle paint only writes even rows or duplicates lines into the 480 bank, SD fetch of odds ≈ empty/duplicate → evenodd stays ~1.0 or rises slightly after ascal smoothing.  
4. **cfg[4] never latched (weaker given any metric move):** Pure null would expect **zero** systematic shift; parent saw Δadj≈−0.011 and mean_adj_diff 0.239→0.155 — **something** in the video chain moved. Not proof cfg[4]=1, but not a perfect no-op either.

**Rule 0:** Source **cannot** prove which of (1)–(4) dominated without a device card that (i) dumps/reads `forced_scandoubler`/timing, and (ii) re-runs **B2-class `push_frame` even/odd** under fsd=0 and fsd=1 on **78eff44e** (same artifact pair). Idle logo is the wrong falsifier for “480 unique store rows.”

### What (c) does **not** mean

It does **not** mean “SD arm is inverted and halves resolution by design.”  
Freeze math for SD is full 1:1 480. Wrong-direction metrics on soft idle+ascal ≠ progressive-arm fetch math.

---

## Consequence (repeat)

| Path | 78eff44e freeze behavior | User default |
|------|---------------------------|--------------|
| `scandouble=0` (cfg[4]=0) | **Even-only / 240 DE** (ceiling) | **Typical HDMI** |
| `scandouble=1` (cfg[4]=1) | 480 fetch in RTL | Optional INI; experiment MISS on idle logo; not a product plan |

**→ Fit must fix progressive arm. Relay to w-fit-1 immediately.**

---

## p_d1 naming (cadence — correct the user sentence)

**Artifact for parent soak (caller-supplied):** RBF `78eff44e` + daemon `7c991e47`.

| Name | Derivation | Is it “1-refresh hold”? |
|------|------------|-------------------------|
| **`p_d1` / `p_delta1`** | Among consecutive **publish notes**, fraction where `unwrap(Δ PLXD[63:48] frames_done) == 1` | **NO** |
| **`p_hold_d1`** | Among publish intervals, fraction where `round(iv_ms / T_vsync) == 1` with `T_vsync` from `vsync_hz` (often **ESTIMATE_60Hz**) | **YES — this is the 1-refresh hitch rate** |

Tip header (`publish_swap_delta_ledger.hpp`):  
`p_delta1_der=frac(delta_frames_done==1)_NOT_hold`  
alias: `p_d1_is=delta_frames_done_eq1_NOT_hold_refresh`.

On **swap-counter** RBF (`78eff44e` packs `frames_done_d2`): **Δfd=1 is the healthy one-swap-per-publish case** → expect `p_d1 ≈ 1.0`, not 0.03.  
Parent’s `p_d1=0.0335` with `p_dge2=0.9639` is **not** interpretable as “3.35% one-refresh holds”; that sentence should be **withdrawn or rewritten** pending tip-daemon `p_hold_d1` / `fd_semantics`.

**Correct user-facing wording (when `p_hold_d1` is measured):**  
“fraction of publish intervals whose length is one display refresh (`round(iv/T_vsync)==1`), derivation hold_d — not Δframes_done.”

Cadence mechanism (unchanged, freeze store `6c39218e`):  
(a) 907e **killed** as 1-hold cause; (b) **no min-2** → 1-hold RTL-legal.

---

## One-line summary for parent → w-fit-1

**INI fsd cannot replace the fit: progressive arm is the product path and still even-only on 78eff44e; make `V_STORE_PROG`/native 480 the fit payload (not SD-only).**
