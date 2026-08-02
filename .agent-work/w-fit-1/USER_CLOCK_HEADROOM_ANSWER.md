# User answer — FPGA MHz headroom (report-only, no fit)

**Author:** w-fit · tip evidence from existing STA  
**Reports used:**  
- `remote_out/fit-t7b-prog480/Plex.sta.rpt` — RBF md5 **`8fdf440f`** (stub present)  
- `remote_out/fit-nostub-chrome/Plex.sta.rpt` — RBF md5 **`c74c6863`** (PRODUCT_NO_STUB)  
**Banned:** do not cite `output_files/` (`2890baac`).

---

## Pre-reg vs actual (publish misses)

| Prediction (before re-read) | Actual | Hit/miss |
|----------------------------|--------|----------|
| clk_sys constrained 20.000 MHz | **20.0 MHz** (period 50.000 ns) STA G0CLK | HIT |
| clk_ddr constrained 90.000 MHz | **90.0 MHz** (period 11.111 ns) | HIT |
| Decode domain = clk_sys general[0] | Confirmed: `Plex.sv` `.outclk_0(clk_sys)`, stream_path/decode on `clk_sys` | HIT |
| Fmax clk_sys @ t7b ~23–24 | **23.46 MHz** | HIT |
| Fmax clk_sys @ c74c ~32–33 | **32.59 MHz** | HIT |
| Fmax clk_ddr ~96–98 | t7b **96.83** / c74c **97.43** | HIT |
| pll.v wizard 100 MHz outs are live | **MISS** — stale megawizard comments; **live** is `pll_0002.v` 3 clocks: 20 / SDRAM / **90** | MISS (important) |

---

## 1) What clock are we on right now?

**Authoritative PLL** (`rtl/pll/pll_0002.v`, not the stale `pll.v` retrieval-info block):

```
.reference_clock_frequency("50.0 MHz"),
.output_clock_frequency0("20.000000 MHz"),   // → clk_sys  (decode / present sys)
.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),  // SDRAM ctrl
.output_clock_frequency2("90.000000 MHz"),   // → clk_ddr  (DDRAM bridge / frame_store DDR side)
```

`Plex.sv`: `.outclk_0(clk_sys)`, `.outclk_2(clk_ddr)`.  
`Plex.sdc` comment (line 9): **general[0] = clk_sys 20 MHz**, **general[2] = clk_ddr 90 MHz**.

STA clock panel (both fits) quotes the same:

| Domain | STA name | Period | Constrained freq |
|--------|----------|-------:|-----------------:|
| **Decode / sys** | `…general[0]…divclk` | **50.000 ns** | **20.0 MHz** |
| **DDR** | `…general[2]…divclk` | **11.111 ns** | **90.0 MHz** |
| HDMI (ascal/OSD) | `pll_hdmi…divclk` | 6.732 ns | ~148.5 MHz pixel (derived) |

**The decode fabric is on 20 MHz**, not the 50 MHz board oscillator (that is the PLL *reference*).

---

## 2) Measured Fmax headroom (quoted STA Fmax Summary)

### A) With fabric decode present — `8fdf440f` / fit-t7b

| Clock | Constrained | **Fmax** | Headroom vs constrained | Setup slack (Setup Summary) |
|-------|------------:|---------:|------------------------:|----------------------------:|
| **clk_sys (decode)** | 20.0 | **23.46** | **+17.3%** | **+0.793 ns** |
| clk_ddr | 90.0 | **96.83** | +7.6% | **+0.333 ns** (tightest in design) |
| pll_hdmi | ~148.5 | 164.93 | | +0.669 ns |

**Crux — which slack is which period:**

- `general[0]` slack **+0.793 ns** is on a **50.000 ns** period (20 MHz), **not** a 10 ns / 100 MHz domain.  
  Critical path data delay (intra) ≈ **42.333 ns** (see path dump).  
  Fmax math: \(1000/(50-7.370) ≈ 23.46\) MHz — matches Fmax Summary exactly.
- `general[2]` slack **+0.333 ns** is **not** “deep clk_ddr ALU”; it is a **half-cycle related CDC** (relationship **5.555 ns** = half of 11.111). Raising `clk_ddr` **tightens** that relationship.

**Intra-clk_sys limiter (sets Fmax 23.46)** — quoted:

```
From: …decode_stub…|lat_p_mb_addr[5]
To:   …decode_stub…|mv_col_al_x[7]
Relationship: 50.000 ns · Data Delay: 42.333 ns · Slack: 7.370 ns
```

### B) Without decode_stub — `c74c6863` / PRODUCT_NO_STUB

| Clock | Fmax | Setup slack |
|-------|-----:|------------:|
| clk_sys | **32.59 MHz** | +0.982 ns |
| clk_ddr | 97.43 | +0.559 ns |
| pll_hdmi | 162.73 | +0.587 ns |

**Do not use 32.59 MHz as “decode Fmax.”** That number is **after removing** the MV path that owned 23.46. Product playback today is ARM decode + DDR present; 32.59 is headroom for **sys-side non-stub** logic only.

---

## 3) vs ao486 / jtcores (cited)

| Core | What runs fast | Source |
|------|----------------|--------|
| **ao486** | Default **CPU 90 MHz** (OSD also 15/30/56); README: *“default core speed is set to 90Mhz”*; `ao486.sv` `clk_rate[0]=90000000` | [ao486_MiSTer README](https://github.com/MiSTer-devel/ao486_MiSTer), `ao486.sv` |
| **jtcores / JTFRAME** | Master fabric **`clk` = 48 MHz** typical (optional **96 MHz** with `JTFRAME_SDRAM96`); original arcade rates via **clock enables** on 24/48, not as the only fabric clock | [jtframe doc/clocks.md](https://github.com/jotego/jtcores/blob/master/modules/jtframe/doc/clocks.md) |

**Comparison that answers the user:**

- Our **`clk_ddr` already runs 90 MHz** — same class as ao486’s default CPU clock. We are **not** “leaving 90 MHz on the table” on the DDR domain; Fmax only ~97 MHz with **+0.333 ns** CDC slack.
- Our **decode/`clk_sys` at 20 MHz is slower than jtcores’ typical 48 MHz master**. Relative to what this FPGA is known to do for *sustained fabric logic*, **yes — 20 MHz is conservative**.  
- jtcores’ *game* clocks (often few–24 MHz via `cen`) are **not** a headroom ceiling; their **FPGA master** is 48/96.

---

## 4) Does raising the clock close the cy/MB throughput gate?

Parent numbers (given): best measured **2,965.8 cy/MB** vs budget **2,667 cy/MB @ 20 MHz** (320×240@25) → miss **~1.11×**.  
Budget scales with clock: \(B(f) = 2667 \times (f/20)\).

| clk_sys | Budget cy/MB | 2965.8 vs budget | Timing close **with decode_stub**? |
|--------:|-------------:|------------------|-------------------------------------|
| 20 | 2,667 | **MISS** | Yes today (Fmax 23.46) |
| **25** | **3,334** | **PASS on paper** (+12%) | **NO with current path** — need Fmax≥25; measured **23.46** |
| 40 | 5,334 | PASS large | **NO** — need ~2× path shrink |
| 50 | 6,667 | PASS large | **NO** without deep pipeline |

**Bottom line for the user:**

1. **Today:** decode domain **20 MHz**, measured Fmax **23.46 MHz** when fabric decode is in the netlist (~17% headroom).  
2. **A free PLL bump to 25 MHz does *not* automatically ship** — STA says the critical decode path is **~42.3 ns**; 25 MHz only gives **40 ns**. You must shorten/pipeline `lat_p_mb_addr → mv_col_al_x` (or equivalent) **before** the budget win is real.  
3. **c74c’s 32.59 MHz Fmax is not a free “decode already closes at 25” proof** — that build **deleted** the limiter.  
4. **Raising `clk_ddr` is the wrong lever for cy/MB** and **hurts** the binding half-cycle CDC (`clk_sys`→`clk_ddr`, relationship 5.555 ns, slack +0.333).  
5. **DDR/scanout freeze risk:** clock changes touch the same `clk_sys`/`clk_ddr` pair that owns bank-swap CDC; any PLL experiment needs the freeze TBs **executed** (PINNOTFOUND = rc=2), elision/timing gates, and an explicit parent fit grant — not a silent frequency edit.

### Realistic raise targets (engineering, not a fit request)

| Target | Cost | Buy |
|--------|------|-----|
| Stay 20 MHz | none | Keep grinding cy/MB (~1.11×) |
| **25 MHz** after ~3 ns path cut / 1 pipeline stage on MV path | modest RTL + **one** timed fit | Unlocks current 2965 cy/MB vs 3334 budget **if** bit-exact holds |
| 40–50 MHz | multi-stage decode pipeline + re-time CDC to ddr | Needed for fat 480p fabric budgets; **not** “PLL only” |

---

## Short blurb suitable to paste to the user

> We’re running the decode/sys fabric at **20 MHz** (PLL out0 from a 50 MHz board ref) and the DDR/frame-store side at **90 MHz**. That’s not a guess — STA lists general[0]=20.0 MHz and general[2]=90.0 MHz, and the live PLL source is `pll_0002.v` (the big “100 MHz” block in `pll.v` is stale wizard text).  
>  
> Measured Fmax on the last good **decode-in** build (`8fdf440f`): **sys 23.46 MHz**, **DDR 96.83 MHz**. So we only have ~17% headroom on the decode clock before timing breaks; the limiter is a real path inside `decode_stub` (~42 ns). DDR already matches **ao486’s default 90 MHz** CPU clock; jtcores typically run a **48 MHz** (sometimes 96) master with slower game enables — so relative to other MiSTer cores we are *low on sys/decode*, not low on DDR.  
>  
> Raising decode to **25 MHz would make today’s ~2966 cy/MB throughput number pass the old 2667@20MHz gate on paper**, but **STA says we do not close at 25 MHz yet** (23.46 Fmax). It is not free headroom — it needs a shorter critical path first, and any clock change has to respect the tight half-cycle CDC into the 90 MHz DDR domain.

---

## No fit requested

Regenerate STA without refit (if db retained): Docker `quartus_sta` on existing `db/` as in JOB1 — already done for t7b.  
Next exclusive fit remains parent-gated (chrome PLXC / other cargo), not a casual PLL bump.
