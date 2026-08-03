# w-clock — 720p overclock proposal (proven headroom only)

**Branch:** `w-clock-bump` (base `w-fit-ceiling-fd-min`)  
**Todo:** `p720-clock`  
**No Quartus fit. No device. PLL bump NOT applied to shipping RTL.**

---

## (a) Verified clock / Fmax facts

### PLL source of truth

| Item | Value | Source |
|------|-------|--------|
| File | `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` | only SoT (no `pll.v` in tree) |
| `reference_clock_frequency` | `"50.0 MHz"` | L43 |
| `output_clock_frequency0` | `"20.000000 MHz"` → **clk_sys** | L46 |
| `output_clock_frequency2` | `"90.000000 MHz"` → **clk_ddr** | L52 |
| out1 SDRAM | macro default `"100.000000 MHz"` | L49 / `MISTERPLEX_SDRAM_PLL_FREQ` |

### Fmax from real STA (re-parsed this session)

| Fit / RBF | clk_sys Fmax | clk_ddr Fmax | clk_sys setup | clk_ddr setup | Command / path |
|-----------|-------------:|-------------:|--------------:|--------------:|----------------|
| **t7b / `8fdf440f`** stub-in | **23.46 MHz** | **96.83 MHz** | **+0.793 ns** | **+0.333 ns** | `check_quartus_timing.py` on `…/fit-t7b-prog480/Plex.sta.rpt` |
| **nostub / `c74c6863`** | **32.59 MHz** | **97.43 MHz** | **+0.982 ns** | **+0.559 ns** | same on `…/fit-nostub-chrome/Plex.sta.rpt` |

Prior write-up `PRODUCT_CLOCK_BUMP_25MHZ.md` numbers **confirmed**.  
Worktree `remote_out/slot11/Plex.sta.rpt` is a **different** fit (clk_sys Fmax **25.09**, and **negative** setup TNS on general[0]/general[2]) — **not** the 8fdf/c74c proof points; do not cite it as product headroom.

### Related-edge (shipping)

- `sys_top.sdc`: all `*|pll|…|divclk` in **one** exclusive group → related clocks.
- STA path panel `clk_sys_worst_setup.txt` (8fdf440f): Launch **general[2]**, Latch **general[0]**, **Relationship 5.556**, Data Delay **3.832**, Slack **+0.793** on `fstore|c_line[9] → c_line_v1[9]`.
- Arithmetic min positive edge 20/90 = **5.555556 ns** (matches).

### Corrections to prior analysis

| Claim | Verdict |
|-------|---------|
| 25 MHz fails STA on stub-in (23.46 < 25) | **Confirmed** |
| 25 MHz plausible on nostub Fmax alone (32.59) | **Intra-sys only** — CDC related-edge collapses to **2.222 ns** |
| 30 MHz cleaner 3:1 | **Confirmed** related-edge **11.111 ns** |
| cy/MB paper gate at 25 MHz | Unchanged paper claim; **not** a present-path 720p requirement |

---

## (b) Derived clk_sys requirement for 720p

### Present path facts (RTL)

From `colorbars.sv`:

- `H_DE = 529`, `H_LAST = 637` → **H_TOTAL = 638** pixel times/line  
- NTSC scandouble: `vc` wraps at **523** → **V_TOTAL = 524**  
- `ce_pix`: toggles when `scandouble=0`; **held 1** when `scandouble=1`

From `present_core.sv`:

- `PRODUCT_V_480 = 1'b1` forces colorbars `.scandouble(PRODUCT_V_480)` → **ce_pix = 1 every clk_sys**  
- `CLK_VIDEO = clk_sys` (`Plex.sv`) → **1 output pixel per clk_sys**  
- Content store (`FRAME_W/H`) is **scaled into** fixed Template DE (`H_DE=529`, V store up to 480 today) — store width alone does **not** raise pixel clock

Current rate check:

```
clk_sys_needed ≈ H_TOTAL × V_TOTAL × fps
20e6 / (638 × 524) ≈ 59.82 Hz   ✓ matches ~60 Hz product display
```

### Three 720p modes (do not conflate)

| Mode | What changes | clk_sys need | Notes |
|------|--------------|-------------:|-------|
| **M0 — Scale-into-template** | FRAME 1280×720 → existing 529×480 DE | **20 MHz (no bump)** | DDR BW + linebufs + stride (w-mem/w-scaler). Scanout budget unchanged. |
| **M1 — Native 720-line DE, keep H_TOTAL=638** | V_ACTIVE=720, V_TOTAL≈750–786, 60 Hz display | **28.71–30.09 MHz** | `638×V_TOTAL×60` |
| **M2 — Native 1280-wide DE @60** | H_TOTAL≈1544 (scaled porches) or CEA 1650 | **69.48 / 74.25 MHz** | **WALL** vs nostub Fmax 32.59 |

### Arithmetic (authoritative)

```
M1:
  638 × 750 × 60 = 28.710 MHz
  638 × 764 × 60 = 29.246 MHz
  638 × 786 × 60 = 30.088 MHz   # V scaled like 524/480

M2:
  1544 × 750 × 60 = 69.480 MHz   # H scaled 1280×638/529
  1650 × 750 × 60 = 74.250 MHz   # CEA 720p60
  1650 × 750 × 30 = 37.125 MHz   # still > nostub 32.59
  1650 × 750 × 24 = 29.700 MHz   # only if display is 24 Hz (usually not)

DDR present BW (coordinate w-mem):
  1280 × 720 × 1.5 × 24 = 33.1776 MB/s ≈ parent 33.2 MB/s
  clk_ddr 90 MHz peak 720 MB/s; 25% read budget 180 MB/s → BW OK
  Line time @20/25/30 MHz (638 clks): 31.9 / 25.5 / 21.3 µs
  Avg line fetch 240 qwords @90 MHz ideal 2.67 µs; @25% eff 10.7 µs → fits line
```

**Binding clk_sys answer for aggressive native 720-line@60 on this timing generator: ~29–30 MHz (Target B).**  
**Binding answer for true 1280-wide@60 1-pixel/clk: impossible on measured Fmax — need wider datapath or stay on M0.**

---

## (c) Staged overclock proposal (PLL strings)

**Applied in tree today:** none (still 20/90).  
**Gate:** `assets/pll_clock_contract.json` + `scripts/check_pll_clock_contract.py` fails unit if PLL drifts without `--allow-pll-bump`.

### Stage 0 — Prerequisite (owned by w-nostub / parent)

1. Product default **nostub** (or proven path-cut) so clk_sys Fmax class stays **≥32 MHz**, not 23.46.  
2. Fresh STA after nostub productization — **do not** reuse c74c6863 alone if RTL moved.  
3. Freeze/shear gates green on RTL (already separate).

### Stage 1 — Target B (preferred): **30 / 90**

`pll_0002.v` (when parent grants fit):

```
.reference_clock_frequency("50.0 MHz"),     // unchanged
.output_clock_frequency0("30.000000 MHz"), // was 20.000000 — clk_sys
.phase_shift0("0 ps"),
.duty_cycle0(50),
.output_clock_frequency2("90.000000 MHz"), // UNCHANGED — clk_ddr
.phase_shift2("0 ps"),
.duty_cycle2(50),
```

| Check | Requirement |
|-------|-------------|
| Intra clk_sys Fmax | **≥ 30.0 MHz** (nostub class 32.59 → ~2.6 MHz margin — placement risk) |
| Intra clk_ddr Fmax | **≥ 90 MHz** (do not raise constraint) |
| Related-edge | **11.111 ns** (3:1) |
| CDC setup | All ddr↔sys timed paths slack ≥ 0 at 11.111 ns relationship |
| CDC hold | **Mandatory** — aligned edges; publish worst hold |
| SDC comment | Rewrite 20→30 and 5.556→11.111 **after** STA quotes new relationship |
| Gate | `check_pll_clock_contract.py --sta-rpt … --activate-target B_30_90 --allow-pll-bump` |
| Present | Enables M1 720-line DE @60 with Template H |

### Stage 2 — Target A: **25 / 90** (not preferred)

```
.output_clock_frequency0("25.000000 MHz"),
.output_clock_frequency2("90.000000 MHz"),
```

| Check | Requirement |
|-------|-------------|
| Related-edge | **2.222 ns** |
| CDC | **Predict HARD_FAIL** if data delay stays ≥3.5 ns (measured 3.832) |
| Use | Paper cy/MB only; **insufficient alone for M1 60 Hz** (need ≥28.7) |

### Stage 3 — Target C: **27 / 90** (fallback if 30 fails intra-sys)

```
.output_clock_frequency0("27.000000 MHz"),
.output_clock_frequency2("90.000000 MHz"),
```

Related-edge **3.704 ns** — still CDC-marginal. Only if B misses Fmax and M1 accepts ~27 MHz with reduced blanking/fps.

### Stage 4 — If M2 (1280-wide @60) is the real goal

Overclock **cannot** get there (need ~70+ MHz). Alternatives:

1. **N-pixels/clk** present datapath (N=4 → ~18.6 MHz for CEA 74.25/4)  
2. **Stay on M0** (scale 1280 store into 529 DE) + HDMI `video_mode` 720p/1080p  
3. Lower tier **960×540** DE: e.g. H≈1158×V≈590×60 ≈ **41 MHz** still above Fmax without multi-pixel  

### Explicitly not in scope

- Raising HPS/DDR3 hard-IP clocks  
- Raising clk_ddr above 90 without new ao486-class evidence + fit  
- False_path / multicycle to hide CDC  

---

## (d) CDC audit table (ratio change)

See also `docs/cdc-crossing-inventory.md` § “Related-edge sensitivity”.

| # | Crossing | Protection today | 25/90 risk | 30/90 risk | Mitigation |
|---|----------|------------------|------------|------------|------------|
| 13 | want_y Gray | Gray 2-FF | Low (protocol) | Low | Keep Gray |
| 14–15 | OSD/status snapshot | Toggle-snapshot | Med (stable window in ns shrinks) | Low | Hold data through toggle |
| 16 | input_fifo | async_fifo AW=2 | Throughput | Throughput | Depth+ if underrun; beat count |
| 17 | line_buf dual-port | M10K | Address stability | Same | None edge |
| 19–21 | m1 want/busy/cmd | 2-FF + hold while !busy | Med (shorter sys ns) | Low–med | Keep protocol; no single-cycle pulses sys→ddr data |
| 22–23 | m1_rsp_fifo | async_fifo AW=3 + reg FWFT | Pointer OK | OK | Existing false_path **only** mem→rd_data_r |
| **meta** | y/c_line, banks → v1/v2 | Related-clock sample | **FAIL** (3.8 > 2.22) | Setup OK if delay holds; **hold** | Retime on ddr; never false_path |

**Evidence class for meta:** `clk_sys_worst_setup.txt` rows with Relationship 5.556 / Data Delay 3.5–3.8.

---

## (e) SDC / gate changes made (this branch)

| Artifact | Change |
|----------|--------|
| `fpga/Plex_MiSTer/Plex.sdc` | Document SoT, shipping 20/90 + 5.556, proposed A/B/C edges, binding 8fdf CDC path, **no new false_path** |
| `assets/pll_clock_contract.json` | Shipping + measured Fmax + targets + 720p arith |
| `scripts/check_pll_clock_contract.py` | Unit + optional STA Fmax floors / `--activate-target` |
| `tests/unit/test_pll_clock_contract.sh` | Red-before-green mutations (bump, low Fmax, missing SDC ptr) |
| `Makefile` + `test_unit_rollcall.py` | Wire gate into `make unit` |
| `docs/cdc-crossing-inventory.md` | Related-edge sensitivity + re-audit table |

**Not changed:** `pll_0002.v` frequencies (still 20/90).

Parent post-fit recipe after a granted bump:

```bash
make post-fit-timing STA_RPT=…/Plex.sta.rpt
make post-fit-timing-margin STA_RPT=…/Plex.sta.rpt
make timing-exclusion STA_RPT=…/Plex.sta.rpt
python3 scripts/check_pll_clock_contract.py \
  --allow-pll-bump --activate-target B_30_90 \
  --sta-rpt …/Plex.sta.rpt
# Plus full path panel: report_timing between general[2] and general[0]
```

---

## (f) Honest ceiling

| Goal | Reachable with overclock alone? |
|------|----------------------------------|
| M0 720p **store** scaled into Template DE | **Yes at 20 MHz** — not a clk_sys problem |
| M1 720-**line** DE @60, H=638, 1 pix/clk | **Only nostub + ~30 MHz** (Target B); stub-in 23.46 is a hard no; margin to Fmax 32.59 is thin |
| M2 1280-**wide** DE @60, 1 pix/clk | **No** — need 69–74 MHz ≫ 32.59 measured. **This is the wall.** |
| M2 @30 Hz 1 pix/clk | **No** — CEA 37.1 > 32.59 |
| Fabric decode cy/MB “25 MHz paper pass” | Possible nostub **if** CDC closes — but 25/90 CDC is the worse ratio; prefer 30/90 for CDC even if cy/MB was the original 25 MHz motivation |

Aggression without STA is forbidden; aggression **with** evidence means: ship nostub, try **B_30_90** once, publish CDC hold/setup, and if M2 is mandatory invent **multi-pixel scanout** rather than dreaming of 74 MHz clk_sys.

---

## (g) Explicit unknowns

1. **Fresh nostub Fmax** after w-nostub product default lands — unknown until that STA exists.  
2. **Actual STA slack at 30/90 or 25/90** — unknown without a fit (predict 25/90 CDC fail; 30/90 setup OK / hold unknown).  
3. **Physical M10K delta** at CODED_W=1280 — unknown without fit (w-scaler/w-mem).  
4. **w-mem final bank map / 33.2 MB/s contention under Linux+ascal** — model only; parent device measures.  
5. **Whether product will choose M0 vs M1** — product call; clock lane sizes both.  
6. **slot11 negative TNS report** in this worktree — provenance unknown; not used as headroom.

---

## Coordination notes

- **w-mem:** 720p24 YUV420 = **33.1776 MB/s** bidirectional present; clk_ddr 90 remains the BW clock; clk_sys bump does not buy DDR beats.  
- **w-scaler / w-nostub:** M1 needs V timing + nostub Fmax; M0 needs linebuf width only.  
- **Parent:** exclusive fit slot for any PLL apply; one menu deploy after BUILD_OK; this lane does not deploy.
