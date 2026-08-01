# JOB 1 — Critical paths for deployed `8fdf440f` (STA re-open, no fit)

**Provenance:** RBF md5 `8fdf440f` =  
`mplex-builds/fit-t7b-prog480/Plex_MiSTer/` (= worktree `remote_out/fit-t7b-prog480/`).  
**Banned:** `output_files/Plex.rbf` = `2890baac` — never cite.  

**Method:** Docker `quartus_sta -t …` against **existing t7b `db/`** (TimeQuest only, **not** a fitter run).  
Artifacts: `.agent-work/w-fit-1/{clk_ddr,clk_sys,pll_hdmi}_{worst,intra}_setup.txt`  
`docker_sta true rc=0`, `intra true rc=0`.

PLL (`rtl/pll/pll_0002.v`): ref 50 MHz → `clk_sys` **20.000**, `clk_ddr` **90.000**.  
Matches parent table. ao486 @ 90 MHz = same class as our `clk_ddr`; jtcores 10–24 MHz ≠ headroom benchmark.

---

## Important distinction (from the report, not assumption)

| Metric | What it measures | Binding number |
|--------|------------------|----------------|
| Setup Summary slack “on clk_X” | Paths that **latch** on clk_X (includes **cross-clock**) | clk_ddr **+0.333** (design worst) |
| Fmax | **Same-clock only** paths | clk_sys 23.46 / clk_ddr 96.83 / pll_hdmi 164.93 |
| Intra setup (this job) | Explicit `-from_clock X -to_clock X` | see below |

The design’s **tightest setup (+0.333)** is a **related-clock CDC**, not the deepest intra-`clk_ddr` comb.

---

## 1) Paths that set **clk_ddr** setup slack +0.333 (tightest in design)

### Worst path latching on `clk_ddr` (quoted)

```
Path #1: Setup slack is 0.333
From Node:     emu:emu|stream_path:spath|ddr_bitstream_reader:ddr_stream|DDRAM_ADDR[3]
To Node:       sysmem_lite:sysmem|sysmem_HPS_fpga_interfaces:fpga_interfaces|f2sdram~FF_857
Launch Clock:  general[0]  = clk_sys (20 MHz)
Latch Clock:   general[2]  = clk_ddr (90 MHz)
Setup Relationship:  5.555 ns   ← half clk_ddr period (related PLL edges)
Clock Skew:         -1.389 ns
Data Delay:          3.713 ns
Logic levels:        1
```

Paths #2–#8 same structure: `ddr_bitstream_reader` `DDRAM_ADDR[*]` / `DDRAM_RD` / `DDRAM_WE` → `f2sdram~FF_*`, slack 0.408…0.688, relationship **5.555 ns**.

**Classification: structural CDC / related-clock half-cycle path**, not “random routing of present scanout”.

- Source is the **stream bitstream DDR reader** (research path), registered in **`clk_sys`**, entering HPS f2sdram on **`clk_ddr`**.
- Only **1 logic level**, data delay ~3.7 ns — tightness comes from the **5.555 ns relationship** (edge alignment of 20↔90 from same PLL), not a deep ALU.
- Product playback DDR traffic is `ddr_frame_store` via arbiter; this worst path is specifically **`ddr_bitstream_reader`**.

### Intra-`clk_ddr` only (sets Fmax 96.83)

```
Path #1: Setup slack is 0.784
From: present_core|ddr_frame_store|desired_y_r[5][4]
To:   present_core|ddr_frame_store|DDRAM_ADDR[28]  (and [12],[10],[27],…)
```

**Classification: structural product path** — line-prefetch Y address → DDRAM address pack inside `ddr_frame_store` on `clk_ddr`.  
Slack **+0.784 ns** ≫ +0.333; Fmax 96.83 ≈ 1/(11.111−0.784) ns domain.

---

## 2) Paths that set **clk_sys** setup slack +0.793

### Worst path latching on `clk_sys`

```
Path #1: Setup slack is 0.793
From: present_core|ddr_frame_store|c_line[9][3]
To:   present_core|ddr_frame_store|c_line_v1[9][3]
Launch: clk_ddr
Latch:  clk_sys
```

(and same family: `c_line`/`y_line`/`y_bank`/`c_bank` → `*_v1` scanout-side registers)

**Classification: structural product CDC** — DDR-domain line buffers into **sys-domain scanout** pipeline (`_v1` suffix). Not incidental glue.

### Intra-`clk_sys` only (sets Fmax 23.46)

```
Path #1: Setup slack is 7.370
From: stream_path|decode_stub|lat_p_mb_addr[5]
To:   stream_path|decode_stub|mv_col_al_x[7]
```

**Classification: structural for the stub, incidental for product pixels.**  
Math check: 1000/(50−7.370) ≈ **23.46 MHz** = reported Fmax exactly.  
⇒ **clk_sys Fmax is limited by dark `decode_stub` motion-vector logic**, not by present scanout.  
`PRODUCT_NO_STUB` removes this limiter; next intra path will set a higher Fmax (unknown until fit).

---

## 3) `pll_hdmi` (overlay home)

```
Path #1: Setup slack is 0.669
From: ascal|o_div[2][20]
To:   ascal|o_hfrac[1][4]
Launch=Latch: pll_hdmi @ 148.54 MHz (period 6.732 ns)
```

**Classification: structural MiSTer scaler** (fractional horizontal accumulator path inside `ascal`).  
Fmax 164.93; slack +0.669. Existing `hdmi_osd` already blends on `clk_hdmi` post-ascal (`sys_top.v`).

---

## 4) Verdicts

### A) Where should the overlay plane sit?

**On `pll_hdmi` / `clk_hdmi`, post-`ascal`, beside existing `hdmi_osd`.**

| Domain | Why / why not |
|--------|----------------|
| **`pll_hdmi`** | Post-ascal pixels + HDMI timing live here; +0.669 ns; existing OSD pattern; w-osd-hires target ≥+0.20 ns is vs **this** domain |
| `clk_sys` | Core DE / bank scanout only (`CLK_VIDEO=clk_sys`); cannot see HDMI output resolution; wrong for bug #2 |
| `clk_ddr` | DDRAM FSM; worst design slack is already here via CDC; no architectural need for chrome |

Adding chrome should be a **shallow post-ascal mux** (like `osd`), **not** logic inserted into `ascal`’s `o_div→o_hfrac` path. Risk: comb depth on `hdmi_data` after ascal — still `pll_hdmi`, must keep slack ≥0 (hard) / ≥+0.20 (soft target).

### B) Can we raise `clk_ddr` above 90 MHz?

**Practically foreclosed as a free win; do not plan on it.**

| Fact | Implication |
|------|-------------|
| Intra `clk_ddr` +0.784 ns | Alone might tolerate ~96 MHz (~needs 0.69 ns less period) with little margin |
| **Binding +0.333** is **clk_sys→clk_ddr half-cycle (rel 5.555 ns)** | Raising `clk_ddr` **shortens the latch relationship** further; this path is already the design minimum |
| 1 logic level, ~3.7 ns data | Not a “pipeline deeper” problem — **edge relationship / CDC** problem |
| Playback not DDR-clock bound | ARM **9.57×** at 480p24; raising MHz moves no user fps |

**Available only after** either (1) re-timing/isolating `ddr_bitstream_reader`→f2sdram (or gating reader in product), or (2) intentional multicycle/false-path **with written CDC proof** — not as a casual PLL bump.

### C) Interaction with planned cargo (no fit yet)

| Cargo | Domain impact |
|-------|----------------|
| **PRODUCT_NO_STUB** | Removes intra-`clk_sys` Fmax hog (`decode_stub` MV path). **Does not** remove `ddr_bitstream_reader` → **+0.333 CDC path remains** unless reader also gated. Frees **−268 M10K / −9.2k ALM**. |
| **plex_chrome (w-osd-hires)** | Must land on **`pll_hdmi`**. Must not deepen `clk_ddr` address path. |
| Raise clocks | **Out of scope** for this fit. |

---

## 5) User-facing summary (MHz / max / headroom)

| Clock | Run at | Fmax | Headroom | Binding path class |
|-------|-------:|-----:|---------:|--------------------|
| clk_sys | **20 MHz** | 23.46 | +17% Fmax | Fmax = **dark stub**; setup slack latch = linebuf CDC |
| clk_ddr | **90 MHz** | 96.83 | +7.6% Fmax | Setup min = **bitstream_reader→f2sdram CDC**; intra = frame_store addr |
| pll_hdmi | **148.54 MHz** | 164.93 | +11% Fmax | **ascal** o_div→o_hfrac |
| vs ao486 | 90 MHz CPU | — | we **match** that class on `clk_ddr` | not “leave headroom on table” vs ao486 |
| vs jtcores | 10–24 MHz | — | **not a benchmark** | original hardware rates |

**Headroom that matters for the next fit:** M10K (88 free → ~356 with stub reclaim) + **pll_hdmi +0.669 ns** for post-ascal chrome — **not** raising 90→96.

---

## 6) JOB 2 readiness (not started — wait w-lint + grant)

**Pre-register (combined PRODUCT_NO_STUB + plex_chrome V1):**

| Metric | Baseline `8fdf440f` | Predict after cargo | Miss if |
|--------|--------------------:|---------------------|---------|
| ALM | 23,585 | **~16.9k ±1k** (−9.2k stub +2.5k±1k chrome) | outside 15.5k–19.5k |
| M10K | 465 / 88 free | **~209 ±4** (−268 +12±4; cap +24 chrome) | free < 300 or chrome >24 |
| DSP | 44 | **44** (+0 chrome, −0..1 stub) | DSP rises |
| clk_ddr setup | +0.333 | **≥ +0.250** (no intentional ddr logic) | < +0.200 |
| clk_sys setup | +0.793 | **≥ +0.793** (stub removed; latch CDC remains) | large drop |
| pll_hdmi setup | +0.669 | **≥ 0 hard; target ≥ +0.20** (w-osd-hires) | negative = HARD_FAIL |
| Hold all | ≥ +0.245 | ≥ 0 | negative |
| TNS | 0 | **0** | any TNS |
| Present ledger | — | **FLAT** | movement = bug |
| Win | — | **1080p overlay pixels** (parent only) | |

**Gates before fit start:** w-lint telem bit-position gate GREEN with red-before-green; freeze/shear/colour/sustained TBs execute (PINNOTFOUND→rc=2); no unjustified `set_false_path`; new RBF ∉ do-not-ship list.

**No fit requested in this job.**
