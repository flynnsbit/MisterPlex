# Internal clock headroom — our side only (no fit, no RTL change)

**Branch tip:** `w-fit-ceiling-fd-min` · Static analysis.  
**PLL SoT:** `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` only (`pll.v` STALE).  
**External jtcores/ao486 comparison:** owned by `r-misterfin` — not duplicated here.  
**Parent ERROR 15 absorbed:** fabric decode justification = **direct-play**, not ARM CPU relief.

---

## Established clocks (quoted)

`rtl/pll/pll_0002.v`:
```
.reference_clock_frequency("50.0 MHz")
.output_clock_frequency0("20.000000 MHz")   // → clk_sys  → STA general[0]
.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ)  // clk_sdram
.output_clock_frequency2("90.000000 MHz")   // → clk_ddr  → STA general[2]
.number_of_clocks(3)   // out3..17 exist as megawizard slots at "0 MHz"
```

`Plex.sv:207-221`:
```systemverilog
wire clk_sys, clk_sdram, clk_ddr;
pll pll (
  .refclk(CLK_50M),
  .outclk_0(clk_sys),
  .outclk_1(clk_sdram),
  .outclk_2(clk_ddr),
  ...
);
```

---

## 1) Module → clock domain → file:line

| Module / block | Domain | Evidence |
|----------------|--------|----------|
| **PLL out0 `clk_sys`** | 20 MHz | `pll_0002.v` out0; `Plex.sv:215` |
| **PLL out2 `clk_ddr`** | 90 MHz | `pll_0002.v` out2; `Plex.sv:217` |
| **`stream_path` (NAL/SPS/PPS/slice_hdr)** | **clk_sys** | `Plex.sv:598` `.clk(clk_sys)`; children `.clk(clk)` at `stream_path.sv:120+` |
| **`decode_stub`** | **clk_sys** | `stream_path.sv:317` `.clk(clk)` same `clk` as stream_path |
| **`h264_dequant4x4` / `h264_idct4x4` / `h264_recon4x4`** | **clk_sys (comb in stub)** | Instantiated under stub `decode_stub.sv:241-257`; **no clock ports** — pure comb on stub nets (`h264_iq_idct_4x4.sv:14+` “Combinational first-block…”) |
| **`h264_mc_block` / `h264_dpb_ref_commit` / deblock path** | **clk_sys** | `decode_stub.sv:646,716` `.clk(clk)` |
| **`ddr_bitstream_reader`** | **clk_sys** | Under stream_path; STA path From `…ddr_bitstream_reader…` Launch **general[0]** (JOB1) |
| **`present_core`** control / scanout side | **clk_sys** | `Plex.sv:736` `.clk(clk_sys)` |
| **`colorbars` video timing** | **clk_sys** | `present_core.sv:146-151` `.clk(clk)` → same present clk |
| **`ddr_frame_store`** fill/DDR side | **clk_ddr** | `ddr_frame_store.sv` `clk_ddr`; `present_core` passes `.clk_ddr(clk_ddr)` `Plex.sv:773` |
| **`ddr_frame_store` scanout CDC into present** | **clk_sys latch** | STA: `c_line`/`y_line` Launch clk_ddr → Latch clk_sys (JOB1) |
| **`ddr_bus_arbiter`** | **clk_ddr** primary; **clk_m1=clk_sys** | `Plex.sv:814-816` `.clk(clk_ddr), .clk_m1(clk_sys)` |
| **`hps_io` / ioctl F1–F3** | **clk_sys** | `Plex.sv:128` `.clk_sys(clk_sys)`; `hps_io.sv:37` |
| **MiSTer `CLK_VIDEO`** | **= clk_sys** | `Plex.sv:849` `assign CLK_VIDEO = clk_sys;` |
| **`CE_PIXEL`** | from present `ce_pix` on clk_sys | `Plex.sv:850` |
| **HDMI ascal path** | **pll_hdmi** (~148 MHz class) | separate PLL; Fmax ~162–165 on t7b/nostub STA — not decode domain |

**Product pixel path today:** ARM → HPS DDR → `ddr_frame_store` (**clk_ddr**) → CDC → present/scanout (**clk_sys**) → `CLK_VIDEO`.  
**Fabric decode ladder (research / dark under DDR):** entirely **clk_sys**, except any future write into DDR would cross to clk_ddr (today stub `fs_wr_*` not connected to `ddr_frame_store`).

---

## 2) Cycle budget vs raising `clk_sys` — direct answer

### Is the decoder on clk_sys @ 20 MHz?

**YES.** Quoted: `stream_path` and `decode_stub` both on `clk_sys` (`Plex.sv:598`, `stream_path.sv:317`). IQ/IDCT/recon are comb leaves of that domain. Measured **2,965.8 cy/MB** (`f5cafa7e` paint_per_mb f0) is a **clk_sys cycle count**.

### Does raising clk_sys “halve cy/MB” and turn 1.11× miss into a pass?

**Clarify the units (rule 0):**

| Quantity | Formula | At 20 MHz | At 40 MHz (if domain scaled) |
|----------|---------|-----------|------------------------------|
| **Measured cy/MB** | paint_cycles / mb_count | **2,965.8** (unchanged by clock) | still **2,965.8** if RTL cycle count unchanged |
| **Budget cy/MB** | f_clk / (MB_per_frame × fps) | 20e6/(300×25) = **2,667** | 40e6/(300×25) = **5,334** |
| Wall-clock time/MB | cy/MB ÷ f_clk | 2965.8/20e6 s | 2965.8/40e6 s (**half**) |
| Gate | measured ≤ budget | **MISS ×1.11** | **PASS ×1.80** on paper |

So:

- **YES** — fabric decode is on **20 MHz clk_sys**, so **wall-clock throughput scales with clk_sys** if cycle counts hold.  
- **NO** — raising the clock does **not** reduce the **cy/MB integer**; it raises the **budget**. Parent’s “halve cy/MB in wall-clock terms” is right as **time**, wrong if read as “the 2965 number becomes 1482.”  
- **NO as a free product knob** — see §4: **`CLK_VIDEO = clk_sys`**, so sys is also the **core video clock**. You cannot raise decode alone by only editing out0 without retiming video (or splitting clocks).  
- **Product pixels today are ARM decode** — clk_sys MHz does **not** change ffmpeg cy/MB or ARM bill. Fabric direct-play is the only path that consumes this budget story.

### 2965.8 quality (prior settlement, short)

`paint_per_mb f0` = mean over 300 MBs of **one IDR**, not max-MB, not multi-frame (`f5cafa7e`, `paint_per_mb = paint_cycles/mb_count`). Tail **unknown**.

---

## 3) Critical path today (on-disk STA)

**Reports used:**  
- `fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.sta.rpt` (stub-in, shipping-class inventory `8fdf440f`)  
- `fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.sta.rpt` (`c74c6863`)  
- Re-opened path detail: `.agent-work/w-fit-1/JOB1_CRITICAL_PATHS_8fdf440f.md` (quartus_sta on t7b db)

### t7b / stub-in (decode mapped)

| Kind | Slack / Fmax | Path | Domain |
|------|--------------|------|--------|
| **Design worst setup** | **+0.333 ns** | `ddr_bitstream_reader` DDRAM_* → f2sdram FF | Launch **clk_sys** → Latch **clk_ddr**, rel **5.555 ns** |
| **clk_sys Fmax** | **23.46 MHz** | `decode_stub\|lat_p_mb_addr[5]` → `mv_col_al_x[7]` | **Intra clk_sys** (dark stub `%` path) |
| Intra clk_sys slack at 20 MHz constraint | +7.370 ns | same path | 1000/(50−7.370)≈23.46 |
| Hold summary clk_sys | +0.245 | STA Setup/Hold tables | |
| Intra clk_ddr Fmax | 96.83 MHz | `ddr_frame_store` desired_y → DDRAM_ADDR | product |

### nostub `c74c6863`

| Kind | Value |
|------|--------|
| clk_sys Fmax | **32.59 MHz** (stub limiter gone) |
| Setup general[0] | +0.982 |
| Setup general[2] | +0.559 |
| Hold general[0] | +0.246 |

**Parent’s “last good +0.375/+0.245, ALM ~21095, DSP 74”** — **not** the t7b report on disk here (t7b is 23585 ALM / DSP 44 / setup worst +0.333). That baseline is a **different RBF class**; do not merge without that RBF’s `Plex.sta.rpt` on disk. **Unknown for that exact md5 — need its STA file.**

---

## 4) What breaks if `clk_sys` goes up?

### Hard pin: video timing is on clk_sys

```systemverilog
// Plex.sv:849-850
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
```

`present_core` → `colorbars` on same `clk` (`present_core.sv:146-151`).  
With product `PRODUCT_V_480` / scandouble hard-wired **1** (`present_core.sv:143-151`):

```systemverilog
// colorbars.sv:51-54
if (scandouble)
  ce_pix <= 1'b1;   // every clk_sys edge is a pixel enable
```

Line length: `H_LAST = 637` → **638 clocks/line** (`colorbars.sv:39`).  
NTSC scandouble vertical last index **523** → **524 lines/frame**.  
Clocks/frame ≈ 638 × 524 = **334,312**.  
At **20 MHz** → ≈ **59.8 Hz** display tick family.  
At **40 MHz** with **same** H/V totals → ≈ **119.6 Hz** — **display rate doubles** unless counters/ce_pix are redesigned.

**Conclusion:** `clk_sys` is **not** a free decode-only clock. It is the **MiSTer core video clock** and the **hps_io/ioctl** clock (`hps_io.sv:37`, `Plex.sv:128`). Raising out0 alone is a **video + host interface** change, not a pure datapath turbo.

### Other sys-domain dependents

| Dependent | Effect of faster clk_sys |
|-----------|---------------------------|
| `hps_io` / SPI ioctl | Runs faster relative to HPS; **unknown** without framework timing review — check: MiSTer expected CLK_VIDEO range / ioctl sampling |
| `present_cadence` | Uses display ticks from colorbars — fps content vs display **shifts** if frame_start rate changes |
| Related CDC sys↔ddr | Edge math changes (25/90 → ~2.22 ns min Δ — prior analysis); **STA required** |
| Audio | `CLK_AUDIO` is separate (`present` `.clk_audio(CLK_AUDIO)`); not out0 |

### Fmax walls (cannot ignore)

| Netlist | clk_sys Fmax | 40 MHz close? |
|---------|--------------|---------------|
| stub-in t7b | 23.46 | **NO** |
| nostub c74c | 32.59 | **NO** at 40; **maybe** 25–30 with margin risk |

---

## 5) Clock-enable / separate decode clock alternative

### Option A — Raise `clk_sys` out0 only  
**Rejected as first move:** video + hps_io + CDC coupled; Fmax < 40 even nostub.

### Option B — Nostub only (drop dark stub, keep 20 MHz)  
**No CDC change.** Fmax 23.46→32.59, −9.2k ALM. Already measured on c74c. **Best cheap headroom for sys domain** without PLL risk. Does **not** by itself change fabric cy/MB budget (still 20 MHz).

### Option C — New PLL out3 = `clk_decode` (e.g. 40–50 MHz), keep out0 = 20 MHz video/hps  
**Most promising for fabric-decode wall-clock** if direct-play is the goal.

| Item | Assessment |
|------|------------|
| PLL capacity | `number_of_clocks(3)` today; megawizard has out3.. slots at 0 MHz — **raising `number_of_clocks` + out3 freq is the intended path**; exact wizard regen **unknown until edited/fitted** |
| Move | `stream_path` / `decode_stub` (and research bitstream reader) onto `clk_decode` |
| Keep on clk_sys | `colorbars`, present scanout control, `hps_io`, `CLK_VIDEO` |
| CDC cost | **New** crossings: ioctl/sys → decode FIFO; decode → (future) DDR write or status telem; existing sys↔ddr present path **unchanged** if present stays 20/90 |
| Prior CDC pain | `ff2e3ca3` hold −0.517; t7b binding +0.333 sys→ddr half-cycle — **do not** add unjustified `false_path`; Gray FIFOs only where already patterned |
| ALM pre-reg | **+0 to +400 ALM** for CDC FIFOs/sync FFs (guess band); decode logic ALM similar; **MISS if >1k without new features** |
| Timing pre-reg | clk_decode Fmax must ≥ target; **unknown** until map — stub-in path is 42 ns comb ⇒ **Fmax~23 on that path still blocks 40 MHz decode** unless nostub or path-cut |
| Dependency | **Option C almost certainly needs PRODUCT_NO_STUB or MV path-cut** before 40 MHz decode closes |

### Option D — Run decode on `clk_ddr` (90 MHz)  
| Pros | Cons |
|------|------|
| Existing 90 MHz domain, Fmax ~97 | Decode is deep comb (42 ns stub path) — **will not close at 90** without massive pipelining |
| | Every ioctl/NAL input is clk_sys — **full CDC surface** |
| | Couples research decode to DDR/present arbiter load |
| Pre-reg | **HIGH risk HARD_FAIL**; not recommended as first step |

---

## Pre-registered scoring table (for later; **no slot requested**)

Baseline for **resource** quotes: prefer **t7b 8fdf** (23585/465/44) or **c74c nostub** (14354/197/43). Parent **21095/74/465** is a third class — attach STA before using.

| Option | ΔALM (pre) | ΔM10K | Timing risk | User-visible now? | Fit worth? |
|--------|------------|-------|-------------|-------------------|------------|
| B nostub @20 | **−9.2k** (measured) | **−268** | Low (done c74c) | Fmax/area only; P2 already | Only with default flip / chrome |
| A clk_sys→40 | ~0 logic | 0 | **HARD_FAIL** Fmax+video+CDC | Would break fps math | **No** |
| C clk_decode 40 + nostub | +0–400 CDC | +0–4 FIFO | Med–high; need STA | Only after fabric decode paints | Maybe later for direct-play |
| D decode on clk_ddr | large pipe | ? | **Very high** | No | **No** now |

---

## What I do **not** know

1. STA for parent baseline **~21095 ALM / DSP 74 / +0.375 setup** — report not identified as t7b/c74c on disk; **check: point at that RBF’s `Plex.sta.rpt`**.  
2. Max-over-MB cy/MB tail (2965.8 is f0 **mean**).  
3. Whether MiSTer framework **requires** a specific `CLK_VIDEO` band for HDMI ascal stability beyond our colorbars math.  
4. Exact ALM of a `clk_decode` CDC shell — **unknown until coded+mapped**.  
5. Whether `ddr_bitstream_reader` must move with decode or can stay gated off in product nostub (soft bus_want tax).  
6. External core comparison numbers — **r-misterfin**.

---

## Short answers for the user-facing compose (internal half)

1. **We run fabric sys at 20 MHz and DDR present path at 90 MHz** (`pll_0002.v`).  
2. **Fabric decode (stub/IQ/IDCT/MC) is on the 20 MHz domain**, not 90.  
3. **Raising 20→40 would expand the cy/MB *budget* and cut wall time**, but **measured cy/MB stays ~2966 until RTL changes** — and **clk_sys is also `CLK_VIDEO`**, so a raw out0 bump **doubles display rate** with current colorbars (ce_pix=1, 638×524).  
4. **Critical path (stub-in):** Fmax 23.46 on dark stub; design-worst setup +0.333 is **sys→ddr CDC** (bitstream reader), not IDCT.  
5. **Highest-leverage safe internal moves:** (1) nostub cargo drop already measured, (2) later **separate `clk_decode` PLL output** for direct-play — **not** a blind clk_sys raise.  
6. **No fit requested.**
