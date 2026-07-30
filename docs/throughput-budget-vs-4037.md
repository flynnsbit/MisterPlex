# Throughput budget vs paint_per_mb ≈ 4037 (rule-0 derivation)

**Owner:** sv-integrate · **Date:** 2026-07-30  
**Measured cost:** phase-2 tip `788aa5f` — `paint_per_mb` frame0 **4036.9** (320) / **3977.9** (624)  
**Authority already in tree:** `docs/decode-throughput.md` (traced 2026-07-27).  
**This note:** re-derive against that authority, **destroy the “~2000 @ 50 MHz” quote**, score 4037, do not invent a new budget.

---

## 1. Target resolution / frame rate (quoted)

| Claim | Quote / source |
|-------|----------------|
| **Product coded default** | `assets/misterplex.conf.example:18–19`: `DECODE=320x240` — *“240p is the current RTL/ARM product path.”* |
| **Profile ceiling (not current ship default)** | `docs/phase3-decode.md:14`: *“Resolution \| ≤ 720p30 or 480p60 (raise after timing)”* |
| **Throughput doc’s realtime case** | `docs/decode-throughput.md:42–43`: target **25 fps**; 480p geometry **624×480 = 1170 MB/frame** |
| **Content FPS in the wild** | Conf allows PMS `Stream@frameRate` / force `fps=` including `24000/1001`, `23.976`, `25` (`misterplex.conf.example` ~63–74). Lab baseline often **vfps≈23** on cast — **not a single hard-coded product fps in RTL**. |

**Product intent for budget purposes:** default **320×240** coded; fps is **stream-dependent**, with docs treating **25 fps** as the ratchet case and **23.976** common for film.  
**Lab stress:** **624×480** is a second-clip / 480p path, not the conf default.

---

## 2. Decoder clock (quoted — not 50 MHz)

```
FPGA_CLK*_50 (50 MHz board osc)          sys_top.sdc: create_clock -period "50.0 MHz"
  └─ pll_0002.v outclk_0 = "20.000000 MHz"   → clk_sys
       Plex.sv: .outclk_0(clk_sys)
       stream_path .clk(clk_sys)             → sink / traverse / stub
```

| Clock | Freq | Role |
|-------|-----:|------|
| **clk_sys (decode)** | **20.000 MHz** | `pll_0002.v` `output_clock_frequency0`; all `stream_path` decode |
| clk_sdram | 50–142 MHz selectable | **Not** decode pipeline |
| clk_ddr | 90 MHz | f2sdram bridge |
| FPGA_CLK1/2/3_50 | 50 MHz | **Board ref only** — not `clk_sys` |

**`docs/decode-throughput.md:29`:** *“The decode clock is 20 MHz. There is no 100 MHz decode path.”*  
**Same doc retracts** older “100 MHz / 3418 cy/MB” as SDRAM-clock confusion.

---

## 3. Where “~2000 cy/MB @ 50 MHz” came from (and why it is not a budget)

| Location | Text |
|----------|------|
| `docs/cycle-iterative-traverse-area.md:205–216` | Example table at **50 MHz → ~2160 cy/MB**; **“Suggested budget allocation (50 MHz, ~2000 cy/MB headroom)”**; total target ≪2000 |
| `docs/cycle-iterative-sink-area.md:107` | *“Full I-MB still ≪ 2000 cy (320×240 @ 50 MHz budget)”* |
| Lane JSON `p2_plane_m10k_prereg_measure.json` | `"budget_cy_per_mb_nominal": 2000` — **no derivation**, inherits the brief |

Those lines are **integrate-lane design suggestions** written during the area diet. They:

1. Use **50 MHz**, which is the **board oscillator**, not `clk_sys`.  
2. Never show `MB/frame × fps` arithmetic against the PLL.  
3. Predate stacking serial RBSP + IQ + I16 + plane RMW.

**Verdict:** “~2000” is **not a repository-derived product budget**. It is an **underived working assumption** that must not drive de-serialisation.  
Parent’s 50 MHz → 5555 cy/MB hypothesis is the same class of error (wrong clock), even though the arithmetic form is right.

---

## 4. Derived budgets (arithmetic shown)

General form:

```
cy/MB_budget = f_clk / ( MB_per_frame × fps )
MB_per_frame = (W/16) × (H/16)
```

### 4.1 Product default 320×240 @ 20 MHz

```
MB/frame = 20 × 15 = 300

@ 25 fps:   20e6 / (300 × 25)     = 20e6 / 7500    = 2666.667 cy/MB
@ 23.976:   20e6 / (300 × 23.976) = 20e6 / 7192.8  ≈ 2780.6  cy/MB
@ 30 fps:   20e6 / (300 × 30)     = 20e6 / 9000    = 2222.222 cy/MB
```

(`decode-throughput.md` table already lists **2666.667** for 320×240 @ 25 fps.)

### 4.2 Lab / profile 624×480 @ 20 MHz · 25 fps (doc ratchet)

```
MB/frame = 39 × 30 = 1170
20e6 / (1170 × 25) = 20e6 / 29250 ≈ 683.761 cy/MB
```

### 4.3 Counterfactual: if someone used 50 MHz (WRONG)

```
320×240 @ 30 fps @ 50 MHz: 50e6 / 9000 ≈ 5555 cy/MB   ← parent hypothesis
320×240 @ 25 fps @ 50 MHz: 50e6 / 7500 ≈ 6667 cy/MB
```

That would make 4037 look like a **pass**. **It is not the product clock.**

---

## 5. Does 4037 pass or fail?

**Measured:** `paint_per_mb` frame0 ≈ **4037** (320) / **3978** (624) at `788aa5f`  
(lane STAGE_CYCLES paint path — I-recon paint cost class, not a full P+deblock+DDR product average).

| Case | Budget cy/MB | Measured | Result | Margin |
|------|-------------:|---------:|--------|--------|
| 320×240 @ 25 fps @ **20 MHz** | **2666.7** | 4037 | **FAIL** | 4037/2667 ≈ **1.51× over** (~51% over budget) |
| 320×240 @ 23.976 @ 20 MHz | **~2781** | 4037 | **FAIL** | ≈ **1.45× over** |
| 320×240 @ 30 fps @ 20 MHz | **2222** | 4037 | **FAIL** | ≈ **1.82× over** |
| 624×480 @ 25 fps @ 20 MHz | **683.8** | 3978 | **FAIL** | ≈ **5.8× over** |
| 320×240 @ 30 @ **50 MHz** (invalid) | ~5555 | 4037 | would “pass” | **do not use** |
| vs underived “~2000” | 2000 | 4037 | “2× over” | **meaningless denominator** |

### Implications (no de-serialise order yet)

1. **Against the traced 20 MHz budget, throughput risk is REAL** for phase-2 paint cost — not an artifact of a fake 2000.  
2. **Against 50 MHz / 5555, risk would be fake** — that clock is wrong.  
3. **Do not undo ALM wins to chase “2000”.** If anything is chased, chase **2667 (320@25)** or **684 (624@25)** with eyes open on area (244 ALM headroom on luma map composition).  
4. **UNKNOWN still:** full product path cycles (P-slice MC + deblock + DDR writeback + present arb) at `788aa5f`; paint_per_mb is necessary but may not be sufficient. Check that settles it: instrument full-frame `summary.cycles` on phase-2 tip the way `decode-throughput.md` did for pre-serial trees.  
5. **Mitigations that are not de-serialise:** raise `clk_sys` (PLL) if timing allows; overlap stages; only then re-parallel selective hot loops.

---

## 6. Remaining ALM composition @ 788aa5f (measured comb ALUTs)

**Whole map ALMs needed = 41,666** (no per-entity ALM column at map).  
Below = **combinational ALUTs** from entity table — composition of logic, not ALM partition.

### 6.1 Top of chip

| Node | Comb ALUTs (self) | DSP | Notes |
|------|------------------:|----:|-------|
| sys_top | 59,007 (1,195) | 111 | |
| emu | 48,057 (118) | 78 | |
| stream_path | 42,122 (147) | 71 | |
| **map_decode_area_probe** | **26,818 (35)** | **37** | **measure tax — not ship** |
| decode_stub | 10,482 (2,036) | 33 | product path (still has parallel dq 32 DSP) |
| **sink** | **8,640 (1,927)** | **4** | phase-2 diet |
| **recon_frame_store** | **8,461 (8,461)** | 0 | **0 M10K bits** — async/uninfer class |
| **traverse** | **7,911 (5,787)** | 1 | |
| present_core | 4,652 (24) | 7 | |
| ddr_frame_store | 4,480 (4,118) | 6 | under present |
| slice_hdr_parser | 3,123 (3,123) | 0 | |
| ascal | 2,906 (2,900) | 23 | scaler |
| deblock_mb | 1,093 (1,093) | 0 | **small — not the wall** |
| mc_block | 909 | 0 | already serial/M10K era |
| … | | | |

### 6.2 Where the “other ~25k” of 41,666 goes

Parent: sink+traverse comb ≈ 16.5k of 41.7k ALMs — remainder?

**Cannot subtract comb from ALMs.** Approximate **logic mass** outside sink+traverse:

| Bucket | Comb ALUTs (order) | Role |
|--------|-------------------:|------|
| **Probe (non-ship)** | **~26.8k** | force-elab had+sink+trav+rfs — **dominates map tree** |
| RFS | **~8.5k** | still reg fabric, 0 BRAM bits |
| decode_stub product | **~10.5k** | parallel dequant 32 DSP still here |
| present + fstore + ascal | **~12k** | display path |
| parsers (slice/sps/…) | **~3k+** | |
| deblock | **~1.1k** | fourth place historically; **not largest now** |
| MC/DPB residual | **~1–2k** | |

**Next area slot (aimed, not guessed):**

1. **Ship composition without probe** — re-map or subtract probe tax before treating 244 ALM headroom as real product margin.  
2. **`h264_recon_frame_store` (~8.5k comb, 0 bits)** — largest **product-ish** decode-adjacent consumer after sink/traverse diet; M10K inference still failed.  
3. **decode_stub parallel dequant (32 DSP + logic)** — retire when serial sink is product-wired (DSP headroom + some ALMs).  
4. **Chroma merge** — still +2k..+12k ALM class; needs room that 244 does not give on probe-inclusive whole.  
5. **Deblock (~1.1k)** — **not** the next ALM fire unless quality demands; leave until RFS/stub/chroma ordered.

---

## 7. One-line answers for parent

1. **Ship coded res:** **320×240** (`DECODE` default). Profile max 720p30/480p60 is aspirational.  
2. **Decode clock:** **20 MHz** `clk_sys`, not 50 MHz.  
3. **Budget:** **2667 cy/MB** (320@25@20MHz); **684 cy/MB** (624@25@20MHz).  
4. **4037 vs budget:** **FAIL ~1.45–1.8×** on 320; **~5.8×** on 624@25. Real risk at 20 MHz.  
5. **“~2000 @ 50 MHz”:** **underived / wrong clock** — do not de-serialise against it.  
6. **Other ALMs:** probe ~27k comb tax; then **RFS ~8.5k**, stub ~10.5k, present path ~12k; **deblock only ~1.1k**.
