# Clock / timing headroom — deployed `8fdf440f` (no fit)

**Artifact:** `.worktrees/w-fit-integ/fpga/Plex_MiSTer/remote_out/fit-t7b-prog480/Plex.sta.rpt`  
(co-located RBF md5 `8fdf440f`; parent-confirmed).  
**Not cited:** main-tree `output_files/` (`2890baac` do-not-ship).  
**Quartus hold:** ON — analysis only.

## PLL / constrained clocks (from STA Clocks panel + `rtl/pll/pll_0002.v`)

| Name in STA | Role | Period / freq (constrained) | Fmax | Setup slack | TNS |
|-------------|------|----------------------------:|-----:|------------:|----:|
| `general[0].…divclk` | **`clk_sys`** | 50.000 ns / **20.0 MHz** | **23.46 MHz** | **+0.793 ns** | 0 |
| `general[2].…divclk` | **`clk_ddr`** | 11.111 ns / **90.0 MHz** | **96.83 MHz** | **+0.333 ns** | 0 |
| `pll_hdmi|…divclk` | HDMI pix (`clk_hdmi`) | 6.732 ns / **148.54 MHz** | **164.93 MHz** | **+0.669 ns** | 0 |
| `h2f_user0_clk` | HPS bridge | 10.000 ns / 100 MHz | 121.12 MHz | +1.744 ns | 0 |
| `spi_sck` | SPI | 10.000 ns / 100 MHz | 286.37 MHz | +6.508 ns | 0 |

PLL source (`pll_0002.v`): refclk 50 MHz; `outclk_0=20.000000 MHz`, `outclk_2=90.000000 MHz`.  
All domains TNS=0; worst setup in design = **+0.333 ns on `clk_ddr`**.

**vs other MiSTer cores (context only):** ao486 soft-CPU class ~90 MHz matches our `clk_ddr` rate; jtcores 10–24 MHz track original hardware — not a max-silicon benchmark. We are **not** Fmax-starved relative to those references; we are **period-constrained with modest positive slack**.

---

## 1) Critical path on `clk_ddr` (+0.333 ns / Fmax 96.83)

### Settled from STA
- Worst **setup** clock in the design is `clk_ddr` (general[2]).
- Intra-clock Fmax **96.83 MHz** ⇒ ~**+7.6%** above 90 MHz constraint.
- Hold on same domain: **+0.330 ns**, TNS 0.

### Path endpoints (From/To registers)
**Unknown — cannot be named from shipped artifacts.**

Evidence of absence:
```text
rg -l 'From Node|To Node|Data Arrival Path' remote_out/fit-t7b-prog480/ mplex-builds/fit-t7b-prog480/
# → no files (exit 1)
```
`Plex.sta.rpt` is the default summary export (Fmax / Setup Summary / Metastability / SI). It does **not** include `report_timing` path panels.

**Check that would settle it** (no refit if timing netlist `db/` kept; parent must authorize Quartus tool use — not started here):

```tcl
# From mplex-builds/fit-t7b-prog480/Plex_MiSTer with existing db/
report_timing -setup -npaths 10 -detail full_path \
  -to_clock [get_clocks {*general[2]*divclk*}] \
  -panel_name {clk_ddr worst setup}
report_timing -setup -npaths 10 -detail full_path \
  -to_clock [get_clocks {*general[0]*divclk*}] \
  -panel_name {clk_sys worst setup}
report_timing -setup -npaths 10 -detail full_path \
  -to_clock [get_clocks {pll_hdmi*divclk}] \
  -panel_name {pll_hdmi worst setup}
```

**What is known to *live* on `clk_ddr` (RTL, not “is the critical path”):**
- `ddr_frame_store`: `always @(posedge clk_ddr)`, line-buffer `wr_clk(clk_ddr)`, `DDRAM_CLK = clk_ddr`, cmd FIFO pop on ddr (`ddr_frame_store.sv`).
- `ddr_bus_arbiter`: `.clk(clk_ddr)` (`Plex.sv`); historical note in that file that a prior CDC placement **failed STA by −1.346 ns** before moving arbiter to `clk_ddr`.
- Present-path DDRAM ports via arbiter m0; stream m1 still present for bitstream reader.

Until `report_timing` runs, any claim that “the limiter is X register” is a **guess** — refused.

---

## 2) Critical path on `clk_sys` (+0.793 ns / Fmax 23.46)

### Settled from STA
- Constrained **20.0 MHz**; Fmax **23.46 MHz** ⇒ operating at **20/23.46 = 85.3% of Fmax**.
- Compare **clk_ddr**: 90/96.83 = **92.9% of Fmax**, absolute slack **+0.333 ns**.
- So **clk_ddr is tighter on both absolute slack and fraction-of-Fmax**. The “20 vs 23.46 looks tight” reading is real headroom (~+17% Fmax) but **not** the design’s binding setup domain — that remains **clk_ddr**.
- Parent note that clk_sys is “tighter ratio” is **not supported** by Fmax% (85% < 93%); both close; **binding setup = clk_ddr +0.333 ns**.

### Path endpoints
Same as above — **not in the report**. Need `report_timing` on general[0].

### What runs on `clk_sys` (RTL evidence)

| Block | Evidence | Product-relevant? |
|-------|----------|-------------------|
| `stream_path` / NAL / SPS/PPS / slice / **`decode_stub`** | `stream_path.sv` `.clk(clk)` ← `Plex.sv` `.clk(clk_sys)` | Stub **dark** for pixels; still burns timing/ALM until PRODUCT_NO_STUB |
| `ddr_bitstream_reader`, `bitstream_fifo` | same `clk` | Soft: can still assert arb m1 `bus_want` |
| `present_core` scanout / `ce_pix` | `.clk(clk_sys)`; `assign CLK_VIDEO = clk_sys` (`Plex.sv:849`) | **Yes** — core video timing + store read address path |
| `audio_ingest`, ioctl/status, telem pack, LEDs | `posedge clk_sys` in `Plex.sv` | Control / status |
| MiSTer `osd` **io side** | `osd.v` `posedge clk_sys` for HPS io | Not the HDMI pixel blend |

**Latency/throughput relevance at 480p24:**  
Scanout on 20 MHz with `ce_pix` is the **core DE clock**, not the HDMI output clock. HDMI pixel path is `pll_hdmi` @ **148.54 MHz**. ARM already has **9.57×** decode+scale headroom at this tier — **raising `clk_sys` does not unlock fps**. It could matter for *fabric* work that needs more cycles per core line (e.g. heavier on-core filters); nothing held today needs that.

---

## 3) Is raising either clock worth doing?

**Agree with parent: NO for playback throughput.**

| Claim | Evidence |
|-------|----------|
| Fabric not fps-bound at 480p24 | Parent ffmpeg flat-out **speed=9.57x** on product 624×480 CB24 |
| Supply pinned upstream | PMS ~1× ladder (parent); not settled here beyond that report |
| Doorbell not hot | Steady-state **~2 µs** (parent PRESENT_PROFILE) |
| 90→96 MHz `clk_ddr` | Would need new PLL constraint + full STA; **no user-visible fps metric** to move at this tier |
| 20→23 MHz `clk_sys` | Same; scanout already feeds ascal; HDMI is separate PLL |

**Disagree only if** a future design is *cycle-starved on clk_ddr* for a measured bandwidth shortfall (DDR beats/line). That is **not** the open user bug and is **not** supported by current throughput data. Do not burn a fit to raise clocks alone.

---

## 4) REAL DELIVERABLE — timing headroom for ADDING logic (OSD + PRODUCT_NO_STUB)

### Domain placement (architecture, quoted)

Post-ascal HDMI path today (`sys_top.v`):

```text
ascal  .o_clk(clk_hdmi)  → hdmi_data
shadowmask .clk(clk_hdmi)
osd hdmi_osd .clk_video(clk_hdmi) .din(hdmi_data_mask) .dout(hdmi_data_osd)
```

`osd.v` blends on **`posedge clk_video`** with integer-expand style counters (`pixsz`/`ce_pix` from DE width).  
`clk_hdmi = hdmi_clk_out` = **`pll_hdmi` @ 148.54 MHz** (STA period 6.732 ns).

**⇒ w-osd-hires post-ascal plane belongs on `pll_hdmi` / `clk_hdmi`, not on `clk_ddr`.**

Reasons (evidence-backed, not preference):
1. **Functional:** must see post-ascal pixels and `HDMI_WIDTH`/`HEIGHT` timing already latched in that domain.
2. **Existing pattern:** `hdmi_osd` already proves the blend-on-`clk_hdmi` integration point.
3. **STA budget:** `pll_hdmi` setup **+0.669 ns**, Fmax **164.93** vs 148.54 ⇒ **~11% Fmax headroom** — double the absolute slack of `clk_ddr` (+0.333).
4. **`clk_ddr` is the wrong home:** hosts DDRAM FSM/arbiter; only +0.333 ns; OSD does not need DDR clock rate; polluting it risks hard-failing `make post-fit-timing` for no architectural gain.

### PRODUCT_NO_STUB timing interaction

- Stub gated today is **`decode_stub` on `clk_sys`** (`stream_path.sv` `ifndef PRODUCT_NO_STUB`).
- Removes large **clk_sys** comb/seq + **M10K** (DPB) — expected to **help or hold** `clk_sys` slack, not stress `clk_ddr`.
- Does **not** by itself remove `ddr_bitstream_reader` / arb m1 (still compiled) — so **do not claim large `clk_ddr` relief** from PRODUCT_NO_STUB alone without a post-fit path diff.
- Telemetry width preserved (`stub_busy=0`); no new cross-domain flags.

### Combined-fit timing risk matrix (pre-register)

| Change | Domain touched | Predicted STA effect | Confidence |
|--------|----------------|----------------------|------------|
| PRODUCT_NO_STUB | primarily **clk_sys** + M10K | slack **≥ baseline** on clk_sys; clk_ddr **flat to slight+** | Med (logic removal) |
| OSD hi-res plane | **`pll_hdmi` / clk_hdmi** pixel path | consumes part of **+0.669 ns**; must stay **≥ 0** | Med-Low until coded |
| OSD on clk_ddr (anti-pattern) | clk_ddr | **risk negative** vs +0.333 | High risk — **do not** |
| Raise clk_ddr 90→96 | clk_ddr | needs ~0.7 ns less period; eats all +0.333 + margin | **Reject** for now |

**Hard gate:** `make post-fit-timing` — any negative slack = HARD_FAIL.  
**Control:** present/throughput ledger **flat** (9.57× ARM headroom).  
**Win:** parent-viewed **1080p overlay pixels**, not MHz.

### Pre-register numbers for combined fit (timing)

| Domain | Baseline slack (8fdf) | Predict after PRODUCT_NO_STUB+OSD on hdmi | Miss if |
|--------|----------------------:|------------------------------------------|---------|
| clk_ddr | +0.333 ns | **≥ +0.250 ns** (no intentional logic add) | drops >100 ps without new ddr logic |
| clk_sys | +0.793 ns | **≥ +0.793 ns** (logic removed) | decreases |
| pll_hdmi | +0.669 ns | **≥ 0.000 ns** (hard); target **≥ +0.200 ns** soft | negative = FAIL |
| TNS all | 0 | **0** | any TNS ≠ 0 |

---

## Bottom line

1. **Cannot name** clk_ddr / clk_sys critical **registers** from shipped STA — summary only. Settle with authorized `report_timing` on existing `db/` (no fit).  
2. **Do not raise clocks** for 480p24 playback — fabric is not the throughput limit.  
3. **Put the OSD plane on `pll_hdmi`**, beside existing `hdmi_osd` / post-`ascal`. Keep **`clk_ddr` lean** (+0.333 ns is the design’s tightest setup).  
4. **PRODUCT_NO_STUB** is an M10K enabler on the way to that plane; timing-wise it should not fight `clk_ddr`.  
5. **No fit requested.**
