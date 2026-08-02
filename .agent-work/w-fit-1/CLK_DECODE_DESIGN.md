# `clk_decode` design note + ranking (no fit)

**Gating dependency (top, not bottom):** Product HDMI pixels today are **ARM decode → HPS DDR → `ddr_frame_store`**. Fabric H.264 is a **probe / research ladder**, dark under `DDR_FRAME_STORE`. **Any fabric-decode clock or pipeline work pays off only for fabric direct-play** (or other fabric that actually replaces ARM work). Parent ERROR 15: H.264 is ~5.8 %onecpu of a ~69 ffmpeg bill; **scaler ~50 %onecpu** — honest ARM offload is not “faster IDCT in fabric.”

---

## ARTIFACT — nostub Fmax **32.59 MHz** (retractable correction for r-misterfin)

**File (on disk in this worktree):**  
`fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.sta.rpt`

**Fmax Summary row (same shape as deploy2 L128):**
```
fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.sta.rpt:128
; 32.59 MHz  ; 32.59 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk           ;      ;
```

**Accompanying identity:**
- RBF: `fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.rbf`  
  md5 **`c74c6863a56ad0d9ef4a24e28af8b7e2`** (prefix `c74c6863`)
- Fit cargo: `PRODUCT_NO_STUB=1` + plex_chrome (BOOT_DEMO); hierarchy `decode_stub` **0 rows**
- Also quoted in: `.agent-work/w-fit-1/BUILD_OK_fit-nostub-chrome.md` (“23.46 → 32.59”)

**Caveats for planners (do not drop these):**
1. **32.59 is nostub product-class Fmax on `clk_sys`**, not “decode already closes at 32 MHz.” The decode Fmax hog was **removed** with the stub.
2. **Not the default QSF** (macro commented; unit requires ALLOW for active). Device may still run stub-in (~23.46).
3. Parent’s independent **deploy2** number **23.46** is the **stub-in / shipping-class** story — both can be true.

Parent may retract the “32.59 does not exist” note to `r-misterfin` **with the path above**. Use it only as **nostub sys headroom**, not as decode-domain headroom.

---

## Roadmap reading — confirm / correct

| # | Parent reading | Verdict |
|---|----------------|---------|
| 1 | Fabric decode throughput is clock-limited (on clk_sys @ 20) | **CONFIRM** for fabric ladder cycle→time. Product pixels are not on that ladder. |
| 2 | clk_sys cannot be raised (video tie + Fmax ~23 stub-in) | **CONFIRM.** Even nostub Fmax 32.59 **≠** free 40 MHz; video still tied (`CLK_VIDEO=clk_sys`). |
| 3 | clk_ddr 90 / ~92 Fmax ⇒ ~2% margin | **CONFIRM** order-of-magnitude (t7b Fmax ddr **96.83**, deploy2 doc **92.14**). Binding design setup is often **related CDC +0.333**, tighter than raw Fmax margin. |
| 4 | Binding constraint on “offload to FPGA” is **Fmax not area** | **PARTLY CONFIRM, with split:** |
| | | **(a) Adding logic into clk_sys @20 with stub-in:** Fmax 23.46 is the wall — **timing before ALM.** |
| | | **(b) After nostub:** sys Fmax 32.59, ALM 14.3k/41.9k, M10K 197/553 — **area re-opens** for overlay/scaler fabric; next limit is **which domain** new logic lands in. |
| | | **(c) clk_ddr / CDC:** already tight — new DDR-side logic or messier related edges **timing-first.** |
| | | **(d) Parent baseline 21095/74/465:** different design class than t7b 23585/44 or c74c 14354/43 — don’t mix. |

---

## 1) Would a decode-only domain close higher Fmax?

### Critical path is **inside** the decode block

t7b intra-`clk_sys` (`.agent-work/w-fit-1/clk_sys_intra_setup.txt`):

```
From Node:  ...|decode_stub:stub|lat_p_mb_addr[5]
To Node:    ...|decode_stub:stub|mv_col_al_x[7]
Data Delay: 42.333 ns
Relationship: 50.000 ns   → Fmax 23.46 MHz
```

RTL source of the comb cone (`decode_stub.sv:524-527`):

```systemverilog
wire [15:0] lat_p_next_mb_addr = lat_p_mb_addr + 16'd1;
wire [15:0] lat_p_next_mb_x16 = ... (lat_p_next_mb_addr % lat_p_mb_width);
wire [15:0] lat_p_next_mb_y16 = ... (lat_p_next_mb_addr / lat_p_mb_width);
```

(`%` / `/` → multi-level cell path into `mv_col_al_x` update.)

### Honest clocking fact

**Fmax ≈ 1 / path_delay.** Moving the **same** 42.3 ns cone onto a wire named `clk_decode` does **not** shrink the cone. Constraining that domain to 40 MHz (**25 ns**) **fails STA** until the path is shortened (pipeline / replace `%` with incremental MB x/y counters).

| Action | Effect on that path |
|--------|---------------------|
| New PLL out3, move stub as-is to clk_decode @40 | **HARD_FAIL** (~23 MHz path in 25 ns period) |
| nostub (delete stub) | Path **gone**; sys Fmax → **32.59** (measured) — but **no fabric decode left to accelerate** |
| Pipeline / kill comb `%` then raise decode clock | **Only** sequence that raises **decode** throughput in MHz |

**So for fabric-decode MHz headroom: the work is pipelining (or restructuring) first, clock second.**  
`clk_decode` without a path cut is a **domain rename that still fails at >~23 MHz** on stub-in netlists.

**Unknown:** next-worst intra path **after** stub removal **if** a reduced decode ladder is re-introduced on clk_decode — **check:** map a minimal decode island + `report_timing -from_clock clk_decode -to_clock clk_decode`. c74c only proves **empty-of-stub** sys Fmax, not future decode Fmax.

---

## 2) CDC cost of a third domain

### Existing (do not weaken)

- `sys_top.sdc`: all `*|pll|…|divclk` (sys+sdram+ddr) in **one** exclusive group → **related** sys↔ddr (5.555 ns @ 20/90).
- `Plex.sdc`: narrow `set_false_path` only `*async_fifo*mem*` → `*rd_data_r*` (Gray 2FF **not** cut).
- Failure memory: `ff2e3ca3` hold **−0.517** on related-edge artifact class.

### New crossings if `stream_path`/`decode_stub` → `clk_decode`

| Crossing | Direction | Pattern | Risk |
|----------|-----------|---------|------|
| ioctl / hps_io bytes | clk_sys → clk_decode | async FIFO + Gray (existing bitstream FIFO style) | Med — must not false_path whole interface |
| status / telem / stub_busy | clk_decode → clk_sys | 2FF or sticky sync | Low–med |
| hybrid flags into present | clk_decode → clk_sys | already loosely used | Med |
| future decode→DDR write | clk_decode → clk_ddr | **new** related or async to ddr | **High** — freeze-class neighborhood |
| clk_decode vs clk_ddr group | SDC | either related (same PLL group) or exclusive | Wrong choice hides CDC or over-constrains |

**ALM pre-reg for CDC shell only:** **+150 to +500 ALM**, **+2 to +8 M10K** (FIFO depths TBD).  
**MISS if** fit shows >1k ALM with “FIFO only” cargo.  
**Do not** add broad `set_false_path` between clk_decode and clk_sys/ddr to “make it close.”

**PLL:** out0 stay **20.000** (video/hps); out2 stay **90.000**; out3 e.g. **25–40 MHz** only after path delay &lt; period. Raise `number_of_clocks` as needed (wizard regen). **Unknown:** exact VCO/M/N until megawizard run.

---

## 3) Pre-registration (score later; no slot now)

### (a) nostub product default @ 20 MHz (no new domain)

| Metric | Baseline stub-in t7b | Expect | HIT if |
|--------|----------------------|--------|--------|
| ALM | 23,585 | ~14,350 | ≤15,500 |
| M10K | 465 | ~197 | ≤220 |
| DSP | 44 | ~43 | ≤45 |
| clk_sys Fmax | 23.46 | **≥30** (hist **32.59**) | ≥28 |
| decode_stub rows | many | **0** | 0 |
| CDC | unchanged 20/90 | hold ≥0 | no new false_path |
| Already measured? | | **YES c74c6863** | re-fit only if sources drifted |

### (b) `clk_decode` @ 40 MHz, stub moved **without** path cut

| Metric | Expect | HIT if |
|--------|--------|--------|
| STA clk_decode | **FAIL** Fmax ~23 | any BUILD_OK without path cut = process bug |
| ALM | +200–500 CDC | |
| Recommendation | **Do not fit** | |

### (c) Path cut (incremental MB x/y, no `%`) on stub, still clk_sys @20

| Metric | Expect | HIT if |
|--------|--------|--------|
| Data delay path | 42.3 → **&lt; 25 ns** aim for 40 MHz later | measured delay or Fmax ≥40 on that cone |
| ALM | **−small to +200** (counters vs lpm_divide) | |
| cy/MB | unchanged by path cut alone | bit-exact 300/300, 1170/1170 |
| Fmax sys stub-in | 23.46 → **?** | publish; may unmask next path ~unknown |

### (d) Path cut + clk_decode @ 25–40 + nostub product (research decode optional)

| Metric | Expect | Notes |
|--------|--------|-------|
| Product default | nostub @20 video | direct-play research may use STREAM + stub on clk_decode |
| ALM product | c74c class + overlay | |
| Decode domain Fmax | only after (c) | **unknown** until fit |
| Risk | High (CDC×2 + pipe) | |

Parent baseline **21095/74/465** for scoring mixed designs: **attach that RBF’s sta/fit before using as B0.**

---

## 4) Rank vs user goal: offload ARM via FPGA/BRAM/DDR

Honest ARM split (parent-measured, ERROR 15): **scaler ≫ H.264 decode**.

| Rank | Option | Real ARM offload? | Risk | Why |
|------|--------|-------------------|------|-----|
| **1** | **(a) nostub @20** — reclaim ~9.2k ALM / 268 M10K | **Enabler**, not offload by itself | **Low** (already fitted c74c; CDC unchanged) | Frees **BRAM/ALM** for work that can replace the **scaler** (~50 %onecpu) or other fabric. Best **capacity** unlock per risk. Does not move H.264 off ARM until something else is built in the hole. |
| **2** | **Fabric scaler / present offload** (uses nostub M10K) | **YES — largest ARM bill** | Med (new datapath, glass) | Aligns with user goal + ERROR 15. Outside pure “decode clock” but **highest offload/$risk**. |
| **3** | **(c) pipeline / kill comb `%` in stub** | Only if fabric decode becomes product | Med (bit-exact) | **Necessary** before any faster decode clock; little ARM win until direct-play productizes. |
| **4** | **(d) clk_decode after (c)** | Direct-play wall-clock | **High** (3rd domain CDC) | Right shape for **fabric direct-play throughput**, wrong as first exclusive; **does not help** until path delay &lt; period. |
| **5** | Raise clk_sys / decode@clk_ddr@90 | No / no | **Hard fail** video or STA | Rejected. |

**Plain statement:**  
For **“offload ARM”** today, **nostub (capacity) → fabric scaler/BRAM work** beats **clk_decode**.  
For **“fabric direct-play H.264”** later, **path-cut then clock** beats **clock then path-cut**.  
**clk_decode alone is not the answer** — the 42 ns cone is.

---

## 5) What we still do not know

1. Next intra-sys critical path on **c74c** (nostub) at full detail — Fmax 32.59 is the number; **endpoint names** need `report_timing` on that db if still present.  
2. Bit-exact impact of replacing `%`/`/` with incremental counters — **check:** existing 300/300 and 1170/1170 gates after RTL.  
3. Whether productizing fabric decode is on the roadmap vs scaler-first — **product call**.  
4. r-misterfin external numbers — not owned here.

---

## No fit requested

Deliverable is analysis only. Parent holds exclusive slot.
