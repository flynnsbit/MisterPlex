# B15 — Runtime content_fps (w-clock)

## Defect (verified)

```
Plex.sv: content_fps = 8'd24;   // HARDWIRED
present_core: beam_vtot_req = (content_fps <= 25) ? 705 : 564;
```

Hardwired 24 ⇒ **V_TOTAL always 705** ⇒ beam always **24.0007 Hz**.
The proven 564-line / **30.0008 Hz** path was unreachable in product.
Parent ARM prize (30 fps present budget) unrealisable as built.

## Recommendation: **PLXG transport** (not fixed-30-only)

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **A. PLXG `content_fps`** | Film 24 and TV 30 both correct; matches true-DE runtime arch; no second hardcode | Needs w-mem pack/latch field (1 byte in existing Q1 gaps) | **RECOMMEND** |
| **B. Fixed 30 Hz core always** | Simpler; clean 2:1 vs HDMI 60; 15.552 Mpix/s < 20 | Film uses repeat not retime; needs **sustained zero-underrun** proof (device/parent); cannot express native 24 beam | Alternate only after underrun proof |

**Why not close with constant 30:** same shape as the defect (architecture pivot leaves a frozen constant). Idle default **30 under BEAM_960** is a fallback until PLXG live, not a freeze — film must set fps=24 via PLXG.

**Fixed-30 underrun:** arithmetic headroom exists (15.55 < 20; B1 wide FIFO 40 peak). **Sustained zero-underrun on silicon is UNKNOWN** (no device; no claim). Do not ship option B on arithmetic alone.

## PLXG field spec (w-mem owns pack + `present_geom_latch`)

5-qword ABI frozen at +0x800 — **no 6th qword**. Use existing Q1 gap nibbles:

```
Q1 layout today:
  [10:0]  content_w
  [15:11] gap (5b)
  [26:16] content_h
  [31:27] gap (5b)
  [42:32] content_x0
  [47:43] gap
  [58:48] content_y0
  [63:59] gap
```

**B15 pack (8-bit content_fps):**
```
content_fps[3:0] = Q1[15:12]     // high nibble of first gap (bit 11 stays 0)
content_fps[7:4] = Q1[31:28]     // high nibble of second gap (bit 27 stays 0)
```
Decode (latch):
```
wire [7:0] content_fps = {sh[1][31:28], sh[1][15:12]};
```
Host `packPlxgQ1` gains optional `uint8_t content_fps` ORed into those bits.
**0 = invalid/unset** → consumer keeps idle default (30 under BEAM_960).
Legal product values: **24** (film → V=705), **30** (TV → V=564). Other values: treat `<=25` as film class else TV class (existing threshold).

**w-clock does not edit** `present_geom_latch.sv` / `plxg_record.hpp` / mux force.
Staged in `Plex.sv`:
```
plxg_content_fps_valid = 0;  // w-mem ties to live_valid && fps!=0
plxg_content_fps = 0;
content_fps = valid ? plxg : idle_30_or_legacy;
```

## Frame-count proof (this lane)

`tests/unit/test_b15_cadence_framecount.sh`
- Wall window = `4 * 1182 * 705` clk_sys cycles @20 MHz
- fps=24 → V=705 → **exactly 4** frames
- fps=30 → V=564 → **exactly 5** frames (`4*705/564 = 5`)
- RED: ignore fps (always 705) while driving 30 → count 4 not 5

## B2_NO_RASTER_GENERATOR note (w-fitgate)

`present_video_timing_960.sv` is **deliberately** math-only (B2b). Sole raster SoT is `present_beam_content_de`. Fit-gate check should **retire or invert** to "must NOT be a generator / must not be dual-instanced" rather than requiring hc/vc in the math pack.
