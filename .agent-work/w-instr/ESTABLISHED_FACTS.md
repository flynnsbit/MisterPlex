# w-instr established facts (parent-measured on device)

## V_STORE 240-row ceiling — ESTABLISHED (not inference)

**Artifact:** HDMI captures after `push_frame --ddr --pattern` on RBF `c5382bee`  
**Path:** product `FpgaSpi::publishDdrFrame`, H.264 out of loop  
**Result (5/5 pre-register hit, std=0.00 all fields):**

| pattern | mean | std | class |
|---------|------|-----|-------|
| mid_grey CONTROL | 137.0 | 0.00 | MID_GREY |
| even_black | 7.0 | 0.00 | BLACK |
| even_white | 255.0 | 0.00 | WHITE |
| odd_black | 255.0 | 0.00 | WHITE (invert) |
| odd_white | 7.0 | 0.00 | BLACK (invert) |

**Meaning:** `store_y=py*2` → only even store rows reach glass. 50% of rows never displayed.  
**Scope limit:** vertical only. H 529/640 is arithmetic + clk_sys=20 MHz (636 < 640), not glass-proven.  
**Before bank for T7:** re-run identical card after w-geom unique-rows 240→480; solid collapse **must break**.

Bank file: `VSTORE_CEILING_BEFORE_c5382bee.json`

## RETRACTED / VOID (do not score as device truth)

| Claim | Status | Why |
|-------|--------|-----|
| p_ge50=14.5% MISS | **UNSCORED** | σ≫mean; raw log gone; remeasure trimmed |
| "two instruments agree" (p_ge50 + acf) | **WITHDRAWN** | one series; preemption manufactures both |
| drops=0 display health | **VOID** | ARM supply; unaccounted≡residual≡publish_misses |
| frames_done on c5382bee | **VOID as swap** | packed bank_vsync_count; advances every vsync |
| PLXD [STALE] freeze detect | **VOID on c5382bee** | frames_done always advances → frozen picture looks healthy |
| period-3 ⇒ 240 rows | **WITHDRAWN** | 480→720 also period-3 |
| spectral cutoff 240 vs 480 | **INCONCLUSIVE** | H.264 band-limited content |

## Standing rules (parent)

1. Publish no field name without its **derivation** in the same breath.
2. Pre-retraction check: same artifact class; device claims need device evidence; "fixed" comments need commit + live artifact.
3. Glass OCR / viewed pixels = only skip/freeze evidence until new RBF packs real `frames_done_d2`.
4. `rc=77`/UNSCORED never a pass. true rc direct, never through a pipe.
5. Device conf is USER-OWNED.

## Primary instruments (w-instr)

| Question | Tool |
|----------|------|
| Display skip/hold | `tools/glass_hold_skip.py` + `glass_template_skip.py` |
| V_STORE ceiling before/after | `push_frame --ddr --pattern` + `hdmi_vstore_discriminate.py --flat-suite` |
| Freeze while STALE void | glass counter motion (not PLXD frames_done) |
| Fabric hold hist | **VOID on c5382bee** until swap counter fitted |

