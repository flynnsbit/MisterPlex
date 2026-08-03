# Multi-pixel-per-clock present datapath

**Lane:** w-clock · **No fit · No device**  
**Macro default:** `PRESENT_MULTI_PIXEL` **undefined** (OFF) · `PRESENT_PX_PER_CLK` defaults to **1**  
**Status:** design + gated RTL landed; **NOT product-wired**. Parent correction: claiming
"scanout done" is overstated — modules are macro-OFF and MiSTer still takes 1 RGB/CE_PIXEL.
Honest claim: **no clk_sys overclock is likely needed** once N-wide path is connected.

Parent confirmed programme facts from scan-out table:
1. 22.12 Mpix/s content touch > shipping 20 MHz @ 1 ppc → nostub is a hard gate for 1 ppc 720p24.
2. CEA 720p60 @ 1 ppc = 74.25 MHz vs nostub Fmax 32.59 → wall, not a PLL tune.
3. Serial ARM decode+copy is dead at every 720p tier (best bank write 15.28 ms/f) → **Route B fabric pixels is mandatory**, not preferred.

This note answers: **does N px/clk rescue 720p without fantasy Fmax?**

---

## 1) Required clk_sys vs N (exact arithmetic)

Definitions:
- **Content rate** = `W × H × fps` (lower bound — no blanking). Must hold to touch every store pixel once/frame.
- **CEA raster rate** = `H_TOTAL × V_TOTAL × fps` with CEA-861 720p `1650 × 750`.
- **clk_sys need @ N ppc** = rate / N  (one beam step produces N consecutive pixels).

Measured Fmax (STA, not guess): stub-in **23.46 MHz** (`8fdf440f`) · nostub **32.59 MHz** (`c74c6863`) · ship PLL **20.00 MHz**.

### 1.1 Content touch (no blanking)

| Mode | Mpix/s | N=1 MHz | N=2 MHz | N=4 MHz | ship20 | stub23.46 | nostub32.59 |
|------|-------:|--------:|--------:|--------:|:------:|:---------:|:-----------:|
| 1280×720×**24** | **22.118** | 22.118 | **11.059** | **5.530** | 1:FAIL 2:OK 4:OK | 1:OK 2:OK 4:OK | all OK |
| 1280×720×**60** | **55.296** | 55.296 | **27.648** | **13.824** | 1–2:FAIL 4:OK | 1–2:FAIL 4:OK | 1:FAIL 2:OK 4:OK |
| 640×480×24 | 7.373 | 7.373 | 3.686 | 1.843 | all OK | all OK | all OK |
| 640×480×60 | 18.432 | 18.432 | 9.216 | 4.608 | all OK | all OK | all OK |

### 1.2 CEA-861 720p full raster (`1650×750`)

| fps | Mpix/s | N=1 | N=2 | N=4 | ship20 | stub | nostub |
|----:|-------:|----:|----:|----:|:----:|:----:|:------:|
| 24 | 29.700 | 29.700 | **14.850** | **7.425** | 1:FAIL 2/4:OK | 1:FAIL 2/4:OK | all OK |
| 60 | **74.250** | 74.250 | **37.125** | **18.562** | 1–2:FAIL **4:OK** | 1–2:FAIL **4:OK** | 1–2:FAIL **4:OK** |

### 1.3 Parent expectation check

| Claim | Computed | Verdict |
|-------|----------|---------|
| 2 ppc → 720p24 near **11–15 MHz** | content **11.059**; CEA **14.850** | **CONFIRMED** |
| 2 ppc → 720p60 near **~37 MHz** | CEA **37.125**; content 27.648 | **CONFIRMED** (CEA) |
| 2 ppc puts 720p60 under nostub 32.59 | 37.125 > 32.59 | **FALSE for CEA raster** — still FAIL |
| 4 ppc CEA 720p60 | **18.562** < 20 ship | **OK even on shipping 20 MHz** (paper; STA of *wider* path unknown) |

### 1.4 Roadmap reframe (this is the point)

| Goal | Min N @ ship 20 MHz | Min N @ nostub 32.59 | Overclock required? |
|------|--------------------:|---------------------:|---------------------|
| 720p24 **content touch** | **2** | 1 (thin) or 2 | **No** if N≥2 |
| 720p24 **CEA glass** | **2** | 1 (B_30) or 2 | **No** if N≥2 |
| 720p60 **content touch** | **4** | **2** | No if N≥4 (ship) or N≥2 (nostub) |
| 720p60 **CEA glass** | **4** | **4** | **No** if N=4 — **2 ppc is not enough** on this Fmax |

**Plain statement:** Parent’s 2 ppc intuition is right for **720p24** (and reframes the roadmap: 720p24 stops needing a PLL bump). It is **not** sufficient for **CEA 720p60** against measured nostub Fmax — that needs **4 ppc** (or a separate fast pix-clock drain; §3).

Contract JSON: `assets/multi_pixel_present_contract.json` · gate: `make multi-pixel-present-contract`.

---

## 2) RTL design — what widens

### 2.1 Today (1 ppc) — sources

| Piece | Behaviour | File |
|-------|-----------|------|
| Beam | `hc` += 1 on `ce_pix`; `H_DE=529`, `H_LAST=637` → H_TOTAL=638 | `colorbars.sv` |
| `ce_pix` | forced `1` via `PRODUCT_V_480` scandouble | `present_core.sv` |
| Store map | `store_x = hc * FRAME_W / 529` | `present_core.sv` |
| DDR read | single `rd_x`,`rd_y` → one RGB | `ddr_frame_store.sv` |
| Line BRAM | 64-bit qword; `pick_byte` uses **1 of 8** Y samples | already wide |
| Out | `CLK_VIDEO=clk_sys`, `CE_PIXEL=ce_pix`, one R/G/B | `Plex.sv` |

**Key free lunch:** M10K already returns **8 Y samples/read**. 1 ppc re-addresses the same qword up to 8 times. N=2/4 is mostly **using the bits we already fetched**.

### 2.2 Parameter

```systemverilog
// Product default: macro OFF → PPC=1 → bit-identical present path.
`ifndef PRESENT_PX_PER_CLK
`define PRESENT_PX_PER_CLK 1
`endif
// Full wire-up of N>1 into present_core / ddr_frame_store only when:
//   `define PRESENT_MULTI_PIXEL
// (undefined in shipping / nostub fit)
```

Legal PPC ∈ {1,2,4}. 1280 is divisible by 2 and 4 — preferred content width.

### 2.3 Blocks that change at N>1

| Block | Change | Notes |
|-------|--------|-------|
| **H counter** | `hc <= hc + PX_PER_CLK` (not +1); compare still vs `H_DE` / `H_LAST` in **pixel** units | Blanking edges must be pixel-aligned; with N\|H_DE and N\|H_TOTAL preferred |
| **H_DE / H_TOTAL** | Native 720: `H_DE=1280`, CEA `H_TOTAL=1650`; Template lock `529` **breaks** (see §4) | 1280%4=0; **1650 is EVEN** (1650%2=0); **1650%4=2** → PPC=4 needs short final step of 2 |
| **ce_pix** | Stays 1 under product scandouble; meaning becomes “beam step valid”, **not** “one pixel” | Rename in docs: `beam_ce` |
| **store_x** | Base `x0 = f(hc)`; lanes `x0+i` for i∈[0,N) with clamp at `FRAME_W-1` | Odd DE tail: `pix_valid[i]` |
| **ddr_frame_store read** | `rd_x` → `rd_x_base` + lane; or one qword + multi `pick_byte` | Prefer multi-pick from same/adjacent qword |
| **YUV→RGB** | N parallel BT.601 lanes (same coeffs as today) | Module: `yuv_bt601_npx.sv` |
| **Line buffer word** | **No widen required** for N≤8 (qword is 8 Y). Optional dual-issue if lane straddles qword | Straddle when `(src_x%8)+N > 8` |
| **DDR burst** | Unchanged (line fill is already bursty on `clk_ddr`) | Bandwidth: 720p24 YUV ≈ 33.2 MB/s ≪ 90 MHz×8 B |
| **Output** | See §3 — MiSTer `CE_PIXEL` is still 1 px/tick unless serializer | |

### 2.4 Odd-width / alignment

| Width | N=2 | N=4 | Rule |
|------:|:---:|:---:|------|
| 1280 content | exact | exact | no tail |
| 529 Template DE | tail 1 | tail 1 | `pix_valid` mask; last clk may have 1 live lane |
| 1650 CEA H_TOTAL | exact (even) | **tail 2** (1650%4=2) | PPC=2 exact; PPC=4 uses variable final step (implemented in `present_beam_ppc`) |
| 624 coded | exact | exact | OK |
| 618 display | exact | tail 2 | mask |

Implementation: always compute N lane coordinates; `pix_valid[i] = in_de && (x0+i < H_DE) && (x0+i < CONTENT_W)`.

### 2.5 Landed RTL (this commit)

| File | Role | Product impact |
|------|------|----------------|
| `rtl/yuv_bt601_npx.sv` | N-lane BT.601 extract from Y/U/V qwords | **Not instantiated** unless `PRESENT_MULTI_PIXEL` |
| `rtl/present_beam_ppc.sv` | Beam counters with +N step, pix-unit blanking | **Not instantiated** unless `PRESENT_MULTI_PIXEL` |
| `rtl/present_npx_path.sv` | N-wide → async_fifo → 1 px/clk (P1 serializer) | **Not instantiated** unless `PRESENT_MULTI_PIXEL` |
| `rtl/present_core.sv` | Comment + optional generate stub under macro | Default OFF — **no behaviour change** |
| `files.qip` | Lists new modules for lint/elab | Compile-only when macro OFF |

---

## 3) Output architecture (how N px/clk reaches glass)

MiSTer product today: `assign CE_PIXEL = ce_pix` and one RGB sample (`Plex.sv`). ascal upscales core DE to HDMI `video_mode`.

Three options (mandate ranking):

| ID | Design | ARM work | clk_sys need CEA60 | Status |
|----|--------|----------|-------------------:|--------|
| **P0** | N-wide **content** path + fabric scaler → **Template DE still 529@1ppc out** | scale off ARM | 20 MHz out OK | Helps 720p24 *decode budget*, not native 720 glass |
| **P1** | N-wide present → **line FIFO** → **separate pix_clk** drain @ 1 px/clk into ascal/HDMI | present off ARM | clk_sys = CEA/N; pix_clk = 74.25 | Preferred native 720p60 |
| **P2** | Single domain: hc steps by N, emit 1 of N via phase on CE | — | Does **not** raise glass px/s | Reject for 720p glass |

**Choose P1 for native glass** (uglier CDC FIFO, ARM fully out of present).  
**Choose P0 first** if the immediate win is shedding ARM scale/present ms while ascal still makes HDMI 720p from Template core timing.

Honest ARM ms: multi-pixel RTL alone removes **0 ms** until wired to replace ARM scale/present. Parent-archived non-decode ~18.6 ms/f @480p; device 720p non-decode **unknown** (parent ~57 ms/f if 3.08× — rd-duck). Measurement to settle: same profile harness with fabric present ON vs ARM scale path.

---

## 4) What breaks (do not paper over)

| # | Breakage | Why | Mitigation |
|---|----------|-----|------------|
| 1 | **`H_DE=529` FBAR Template lock** (`present_core.sv:172`, `colorbars.sv`) | Entire FBAR/DE_LAG/eyes-on corpus assumes 529 | New mode flag `PRESENT_TIMING_720`; keep 529 path for regression; do not retcon goldens |
| 2 | **`DE_LAG=3`** calibrated on 320 RGB565 | ddr_frame_store deeper; N-wide changes pipeline depth | Re-sweep `gen_edge_markers.py` on authorised fit; parameterise `DE_LAG` |
| 3 | **`ce_pix==1` ⇒ 1 pixel** assumption | Ubiquitous in comments, cadence mental model, tests | Document `beam_ce`; audit tests for hc delta==1 |
| 4 | **Glass instruments** (HDMI capture crop, pillar metrics, 0.604 UVC class) | Geometry in capture space changes if core DE widens | Version instrument profiles per timing mode |
| 5 | **`STORE_X_SCALE = FRAME_W*39647/320` toward 529** | Wrong for H_DE=1280 identity | Identity map when `FRAME_W==H_DE` |
| 6 | **10-bit `hc`/`vc`** | 1650 needs 11 bits | Widen to 12 bits in `present_beam_ppc` |
| 7 | **Single `rd_r/g/b` port** on `ddr_frame_store` | API is 1 px | Add `rd_r_nx[N]` under macro; keep scalar ports as lane0 |
| 8 | **ascal / `CE_PIXEL` 1-px contract** | Cannot feed N RGB without sys change or FIFO | P1 serializer (§3) |
| 9 | **CEA 1650 % 4 = 2** | Pure +4 step leaves 2 px tail | Variable final step in `present_beam_ppc` (done); do not claim 1650 is odd |
| 10 | **w-scaler merge** | Same file `present_core.sv` | Frozen interface §5 |

---

## 5) Interface contract with w-scaler (paper freeze)

Both lanes touch `present_core.sv` / store read. **Single shared stream:**

```text
namespace present_px_stream (clk_sys):
  param int PPC = PRESENT_PX_PER_CLK;  // 1|2|4

  // Beam (owned by w-clock present_beam / colorbars)
  logic        beam_ce;                 // was ce_pix
  logic [11:0] glass_x0;              // left pixel of group (glass space)
  logic [11:0] glass_y;
  logic [PPC-1:0] glass_de_lane;      // per-lane DE
  logic        frame_start;

  // Store sample coordinates (owned by scaler map)
  // w-scaler: glass → content/store. w-clock multi-pixel: does not resample; only N-wide issue.
  logic [11:0] store_x0;              // content/store X for lane 0
  logic [11:0] store_y;
  logic [PPC-1:0] store_x_phase;      // optional subpixel for filter (scaler)
  logic [PPC-1:0] store_lane_valid;

  // Pixel data after YUV (owned by w-clock ddr_frame_store N-extract)
  logic [7:0]  yuv_r[PPC], yuv_g[PPC], yuv_b[PPC];
  logic [PPC-1:0] yuv_ready;

  // Pixel data after scaler (owned by w-scaler)
  logic [7:0]  out_r[PPC], out_g[PPC], out_b[PPC];
  logic [PPC-1:0] out_ready;

  // Identity shortcut when content size == glass DE (720p native present):
  //   store_x0 = glass_x0; out_* = yuv_*; scaler is wires.
```

**Ownership:**
- **w-clock:** beam step N, YUV N-extract, line-buffer addressing, pix_clk FIFO (P1), PLL/SDC.
- **w-scaler:** glass↔content map (scale/pad/crop), filter coeffs, when `CODED ≠ DISPLAY`.
- **w-mem:** `CODED_W=1280` bank layout, doorbell, stride (1280 Y/line = 1 M10K).

**Merge rule:** scaler PR must not hardcode `hc+1` or `H_DE=529` without `ifdef` timing mode. Multi-pixel PR must not hardcode scale math.

**Assumption frozen here for w-scaler:** first integration is **PPC=2**, content **1280×720**, glass mode either (a) identity 1280 DE, or (b) scale-to-529 under `PRESENT_TIMING_TEMPLATE` for dual-path bring-up. Default build remains Template 1 ppc.

---

## 6) Cost (ALM / M10K) and Fmax risk — honest

### 6.1 M10K (geometry-driven, not N-driven)

| Item | 624-class (today order) | 1280-class | Notes |
|------|-------------------------|------------|-------|
| Y line bits | 624×8 = 4992 | **1280×8 = 10240 = 1.0 M10K** | Parent note: exact one M10K |
| Y slots | `LINE_COUNT*2` (default 8) | same count × larger depth | Depth folds into same M10K until >10Kb |
| U/V line | half width | 640×8 = 0.5 M10K each | |
| **N=2/4 extra BRAM** | **0** if single 64b port reused | **0** baseline; +1 port only if dual-qword straddle design | |

N does **not** multiply line BRAM. 720p geometry does.

### 6.2 ALM / DSP (N-driven)

| Piece | N=1 (today) | N=4 estimate | Confidence |
|-------|-------------|--------------|------------|
| BT.601 lane | 1× (3 mul + add) | 4× | high structure |
| DSP preference | soft or 3 DSP | **12 DSP** if mapped | med — depends on quartus mul infer |
| Soft mul ALM | ~order 0.3–1k ALM class (not tape-measured here) | ×N | **unknown** — need map.rpt |
| Beam +valid mask | tiny | tiny | high |
| Output FIFO P1 | 0 | 1 line × 1280×24 ≈ 30 kb ≈ 3 M10K | med |

**No ALM number from a real map.rpt for N=4 is claimed.** Unknown until fit. Order-of-magnitude only: DSP-friendly N=4 is cheap in ALM, hungry in DSP (5CSEBA6 has 87 DSP — 12 is OK).

### 6.3 Fmax risk → net

Wider parallel YUV **can lower** clk_sys Fmax while **lowering required** frequency.

| Path | Required @ N=4 CEA60 | Required @ N=2 CEA24 | Today's nostub Fmax | Net if Fmax drops 20% (26.1) | Net if drops 40% (19.6) |
|------|---------------------:|---------------------:|--------------------:|:----------------------------:|:------------------------:|
| CEA 720p60 | 18.56 | — | 32.59 | **OK** | **FAIL thin** |
| CEA 720p24 | 7.43 | 14.85 | 32.59 | **OK** | **OK** |
| Content 720p24 | 5.53 | 11.06 | 32.59 | **OK** | **OK** |

**Net opinion (not STA):** N=4 is the robust CEA60 choice because required 18.56 leaves headroom even if wider path hurts Fmax moderately. N=2 is the **720p24 no-overclock** choice and is the right first enable. **STA after first multi-pixel fit is mandatory; until then Fmax impact = unknown.**

---

## 7) Staged enable plan (no fit now)

| Stage | Action | Fit? |
|------:|--------|:----:|
| S0 | This design + RTL modules + contract gate; macro OFF | no |
| S1 | w-mem 1280 layout; w-scaler map hooks honor §5 | no/parallel |
| S2 | Parent fit: nostub reclaim only (no multi-pixel) | w-nostub |
| S3 | Enable `PRESENT_MULTI_PIXEL` + `PRESENT_PX_PER_CLK=2` on identity 720 content → Template or 1280 DE lab | **one** grant |
| S4 | STA Fmax/slack publish; DE_LAG resweep | parent HW |
| S5 | PPC=4 if CEA60 glass targeted; P1 pix_clk FIFO | later grant |

PLL Target B_30_90 becomes **optional** for 720p24 if S3@N=2 meets timing at 20 MHz — still useful for fabric-decode cy/MB and M1 1ppc paths.

---

## 8) Ceiling statement

- **720p24 is not clk-starved** if present emits **≥2 px/clk** (11–15 MHz need < 20 MHz ship).
- **720p60 CEA glass is not reachable at 2 ppc** on measured nostub Fmax (37.1 > 32.6); **4 ppc (18.56 MHz)** is the arithmetic escape without multi-GHz fantasy.
- **1 ppc + PLL bump cannot save CEA 720p60** (74 MHz wall).
- Multi-pixel is the mandate-aligned lever: parallel fabric work, not ARM, not blind overclock.

---

## 9) Unknowns (rule 0)

| Unknown | Settling artifact |
|---------|-------------------|
| Fmax with N=2/4 YUV parallel | map+sta after S3 fit |
| ALM/DSP exact | same map.rpt |
| DE_LAG for N-wide ddr path | HDMI edge sweep |
| ARM ms removed | parent profile fabric present ON vs ARM scale |
| Dedicated clk_pix PLL + top CE_PIXEL mux | parent fit grant; wire `present_npx_path` out to Plex.sv |
| ddr_frame_store N-wide ports | **landed** `PX_PER_CLK` default 1: `rd_r_n`=`rd_r`; N>1 generate → `yuv_bt601_npx` on commit snapshot |
| Real 720p cy/MB fabric decode | decode bench (not this lane) |
