# w-clock — 720p overclock proposal (proven headroom only)

**Branch:** `w-clock-bump` (base `w-fit-ceiling-fd-min`)  
**Todo:** `p720-clock`  
**No Quartus fit. No device. PLL bump NOT applied to shipping RTL.**

---

## Mandate (parent 2026-08-03)

> The whole point is to move as much into the FPGA so we can do 720p.

720p is the **reward for evacuating the ARM**, not a side feature. Dual ARMv7,
**41.7 ms/frame @24 fps**. Parent device evidence tonight:

| Workload | ms/frame | Source |
|----------|---------:|--------|
| 1920×1080 Constrained Baseline synthetic blip, 200 frames | **32.4** | parent wall 6.486 s / 200, true rc=0 |
| 624×480 real-content `decode_null` (archived) | **21.562** | parent archive |
| Pixel ratio 1080p/480p | 6.9× | arithmetic |
| Time ratio | **1.5×** | 32.4 / 21.562 |

**Steer:** ARM H.264 cost here tracks **content/bitrate more than pixel count**
(caveat: 1080p clip is synthetic low-bitrate; real 720p content pending parent).
Therefore the budget 720p needs is freed by **removing non-decode ARM work and
eventually decode itself into fabric** — scale, overlay, idle paint, pacing,
memcpy — not by shaving a few percent off swscale.

**Clock-lane doctrine under this mandate:**

1. Prefer the clock plan that makes **ARM do none of the job** (fabric decode +
   native 720p present) over one that only makes ARM’s remaining job cheaper.
2. Size every present/decode timing assumption for **1280×720** as the first-class
   geometry (line = 1280 B = **exactly one M10K** for 8-bit luma bytes; Y line
   qwords = 160 @64b).
3. Quantify ARM ms/frame removed — or say **unknown** + the measurement.
4. When elegant-but-ARM-still-in-loop vs ugly-but-ARM-out: **choose ARM-out.**

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

### Three 720p modes — ranked by ARM evacuation (mandate order)

| Rank | Mode | clk_sys need | ARM still in loop? | Verdict under mandate |
|-----:|------|-------------:|--------------------|------------------------|
| **1** | **F — Fabric decode + native 720p present** | **≥25–30 MHz** (cy/MB below) + present need | **Decode: no. Scale: no.** | **Primary goal.** Clock exists to make this realtime. |
| **2** | **M2 — Native 1280×720 DE @60, 1 pix/clk** | **69–74 MHz** | Present path fabric; ARM may only feed bitstream/frames | **WALL** on Fmax 32.59 without multi-pixel/clk datapath |
| **3** | **M1 — Native 720-line DE, H_TOTAL=638 @60** | **28.7–30.1 MHz** | ARM can push full 720p frames w/o downscale to 480 canvas | **Best present-only step** reachable by overclock alone |
| **4** | **M0 — Scale 720p store into 529×480 Template DE** | **20 MHz** | ARM or fabric still **destroys 720p detail** into 480-class canvas | **Rejected as product end-state** — keeps a reduced job on the path. Interim glass-only only. |

**Why M0 loses:** it is the elegant “no clock bump” path, but it leaves the system
doing 480p-class presentation forever. Mandate: ugly multi-pixel M2 or fabric
decode at 30 MHz beats polished M0.

### Fabric-decode clk_sys budget (primary overclock driver)

Decode runs on **clk_sys** (`docs/decode-throughput.md`). Geometry 1280×720 =
**80×45 = 3600 MB/frame**.

Measured full-frame class cost (480p fixture): **~259 cy/MB**
(`plex_inter_p16_baseline_624x480_12f.264` in decode-throughput.md).  
**Unknown** whether 720p content lands at the same cy/MB — settle with the same
harness on a 1280×720 fixture after fabric decode accepts that size.

| clk_sys | fps | cy/frame | budget cy/MB | vs 259 cy/MB |
|--------:|----:|---------:|-------------:|--------------|
| 20 | 24 | 833 333 | **231.5** | **MISS** (0.89×) |
| **25** | 24 | 1 041 667 | **289.4** | PASS ~1.12× (paper) |
| **30** | 24 | 1 250 000 | **347.2** | PASS ~1.34× (paper) |
| 20 | 30 | 666 667 | 185.2 | MISS |
| 30 | 30 | 1 000 000 | 277.8 | PASS ~1.07× thin |

So: **shipping 20 MHz cannot carry fabric-decode 720p24 at measured cy/MB.**
That alone justifies a nostub overclock **independent of present DE**. Target B
(30 MHz) is preferred over A (25 MHz) because CDC related-edge is safer **and**
720p30 fabric decode stays on the right side of 259 cy/MB.

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
| **F** Fabric-decode 720p24 @ ~259 cy/MB | **Needs ≥25 MHz paper; prefer 30 MHz** + nostub Fmax ≥ target + CDC close. **20 MHz is a hard miss (231 < 259).** |
| M1 720-**line** DE @60, H=638, 1 pix/clk | **Only nostub + ~30 MHz** (Target B); stub-in 23.46 is a hard no; margin to Fmax 32.59 is thin |
| M2 1280-**wide** DE @60, 1 pix/clk | **No** — need 69–74 MHz ≫ 32.59. **Present-path wall.** Escape: **N-pixels/clk** (N≥3 for ~25 MHz, N=4 for ~18.6 MHz) sized for 1280 from day one |
| M0 scale-into-480-canvas | Works at 20 MHz but **fails the mandate** as an end-state |
| M2 @30 Hz 1 pix/clk | **No** — CEA 37.1 > 32.59 |

Aggression without STA is forbidden. Aggression **with** evidence: ship nostub → fit **B_30_90** once → publish CDC hold/setup → unlock fabric-decode 720p24 cy/MB gate **and** M1 present. For true 1280-wide glass at 60 Hz, **do not wait for a fantasy 74 MHz clk_sys** — design multi-pixel scanout (ARM-out present) instead of M0 forever.

---

## (f2) ARM milliseconds removed — clock lane claim

Frame budget @24 fps = **41.67 ms**.

| Offload unlocked by this clock plan | ARM ms/frame removed | How we know |
|-------------------------------------|---------------------:|-------------|
| **Fabric decode replaces ARM H.264** (end-state F) | **21.562 ms/frame** class at 480p real `decode_null`; **32.4 ms/frame** at parent’s 1080p synthetic blip | Parent/device decode_null and tonight’s wall measurement. **720p real-content decode_null: unknown — parent measuring.** Not extrapolated from pixel count (parent showed 6.9× pixels ≠ 6.9× time). |
| **Native 720p present eliminates ARM swscale-to-tier** | **~21 ms/frame** class **if** 480p soak vf~50.4% onecpu was scale and is fully dropped | `docs/evidence/p480-headroom-*` + p720-scope-arm: vf~50.4% onecpu → 0.504×41.67≈**21.0 ms/frame** CPU-equivalent under realtime. **Only counts when scale is actually gone** (PMS delivers 1280×720 **or** fabric outputs 720p and host skips vf). S1 stream geometry still open in that report. |
| **clk_sys bump alone with ARM still decoding+scaling** | **0 ms** | Clock does not run ARM code. Paper cy/MB is fabric-side. |
| **M0 scale-into-template** | **0 ms decode; scale may remain on ARM** | Canvas still 480-class; host path often still has vf. |

**This lane’s direct, honest claim today:**  
shipping **20 MHz blocks fabric-decode 720p24** (cy/MB arithmetic). Moving to **30 MHz (B)** is a **necessary enabler** for the offload that removes the **21–32 ms/frame decode class** — but the bump **by itself removes 0 ms** until fabric decode is the product path.  
**Do not credit scale ms to the PLL file.** Credit scale ms only when present is native 720p **and** host drops vf (host/w-mem/w-scaler evidence).

**Measurement that would settle residual unknowns:**

1. Parent: real 720p content `decode_null` ms/frame on device (in flight).  
2. Parent: ffmpeg `-benchmark` / `time=...` with vf on vs vf omitted on same 720p URL.  
3. After fabric decode accepts 1280×720: Verilator cy/MB on a 720p fixture at clk_sys=20 vs 30.

---

## (g) Explicit unknowns

1. **Fresh nostub Fmax** after w-nostub product default lands — unknown until that STA exists.  
2. **Actual STA slack at 30/90 or 25/90** — unknown without a fit (predict 25/90 CDC fail; 30/90 setup OK / hold unknown).  
3. **720p fabric-decode cy/MB** — unknown; 259 cy/MB is 480p fixture class only.  
4. **Real 720p ARM decode_null ms/frame** — parent measuring; do not use 32.4 as 720p truth.  
5. **Physical M10K delta** at CODED_W=1280 — unknown without fit (note: 1280 luma bytes = 1 M10K depth class).  
6. **w-mem final bank map / 33.2 MB/s contention under Linux+ascal** — model only.  
7. **Whether host will skip scale** when fabric is native 720p — unknown until daemon policy lands.  
8. **slot11 negative TNS report** in this worktree — not used as headroom.

---

## Coordination notes

- **w-mem:** size banks/strides for **1280×720 from the start** (1.32 MiB/frame, stride ≥2 MiB class); 33.18 MB/s @24fps; clk_ddr 90 stays BW clock.  
- **w-scaler:** prefer native 720p window / multi-pixel scanout over eternal Template-529 pillar; M0 is not the mandate end-state.  
- **w-nostub:** required before any bump (Fmax 23.46 → ≥30 class).  
- **Decode lanes:** 30 MHz is the fabric-decode 720p24/30 enabler; keep cy/MB harness honest.  
- **Parent:** exclusive fit for PLL apply; all device ms/frame scores are parent-owned.
