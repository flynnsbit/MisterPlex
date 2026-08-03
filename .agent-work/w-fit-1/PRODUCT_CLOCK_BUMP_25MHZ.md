# Product clk_sys 25 MHz bump — shipping proof, PLL proposal, CDC (no fit)

**Branch tip context:** `w-fit-ceiling-fd-min`. **No Quartus fit. No device.**  
**PLL SoT:** `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` only (`pll.v` megawizard strings are STALE).

---

## 1) What actually ships (do this first)

### QSF / define

| Source | Evidence |
|--------|----------|
| **Product default policy** | `tests/unit/test_product_no_stub_dark_silicon.sh:157-167` — active `PRODUCT_NO_STUB` **FAILS** unit unless `ALLOW_PRODUCT_NO_STUB_ACTIVE=1`. Comment form required: `# set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"`. |
| **Tip QSF after this write-up** | `PRODUCT_NO_STUB` **commented** (product default). `DDR_FRAME_STORE=1` remains on. |
| **RTL when macro off** | `stream_path.sv` `` `ifndef PRODUCT_NO_STUB `` **instantiates** `decode_stub` (~L312–363). |
| **RTL when macro on** | else branch **ties** `stub_busy = 1'b0` (~L384); no stub instance. |

### Hierarchy (fitted RBFs)

| RBF | `decode_stub` in fit.rpt | clk_sys Fmax (STA) |
|-----|--------------------------|--------------------|
| **t7b / `8fdf440f`** (`fit-t7b-prog480`) | **YES** — many `stream_path:spath\|decode_stub:stub\|…` rows | **23.46 MHz** (`Plex.sta.rpt` Fmax Summary L128) |
| **nostub / `c74c6863`** (`fit-nostub-chrome`) | **NO** — `rg decode_stub Plex.fit.rpt` → **0 hits** | **32.59 MHz** (`Plex.sta.rpt` Fmax Summary L128) |

### Plain statement (inverts naive “product already free”)

1. **Default product QSF maps `decode_stub`.** Shipping *source default* is **not** `PRODUCT_NO_STUB`.  
2. **`c74c6863` is the nostub proof point**, not the standing unit-default. Parent must redeploy nostub for device to match that netlist.  
3. **`c5382bee` stub presence:** **unknown without that RBF’s hierarchy** (ALM ~21k class ≠ nostub 14.3k). Do not assume.  
4. Therefore: **25 MHz product bump is STA-plausible only for a nostub (or path-cut) netlist.** Default stub-in netlist Fmax **23.46 < 25** — PLL-only bump **fails STA** on that config.

**Tip was left with ACTIVE `PRODUCT_NO_STUB=1` after fit-nostub-chrome cargo → `make unit` HARD FAIL on product-default gate. Restored to commented.**

---

## 2) PLL proposal (document only — **not applied**)

### Target A — 25 MHz clk_sys, clk_ddr **unchanged** 90 MHz

File: `rtl/pll/pll_0002.v`

```
.reference_clock_frequency("50.0 MHz"),   // unchanged
.output_clock_frequency0("25.000000 MHz"), // was 20.000000 MHz  → clk_sys
.phase_shift0("0 ps"),
.duty_cycle0(50),
.output_clock_frequency2("90.000000 MHz"), // UNCHANGED → clk_ddr
.phase_shift2("0 ps"),
```

| Param | Before | After (proposed) |
|-------|--------|------------------|
| clk_sys (out0) | 20.000 MHz / 50.000 ns | **25.000 MHz / 40.000 ns** |
| clk_ddr (out2) | 90.000 MHz / 11.111 ns | **90.000 MHz (do not raise)** |
| Ref | 50.0 MHz | 50.0 MHz |
| Integer feasibility | 50×(N/M) → 20 | 50/2 = **25 exact** |

Also update comments in `Plex.sdc` that hardcode “20 MHz” / “5.556 ns” after any real fit (do not retcon without STA).

### Target B — 30 MHz clk_sys (report only)

| Need | Value |
|------|--------|
| PLL string | `.output_clock_frequency0("30.000000 MHz")` (50×3/5) |
| vs nostub Fmax 32.59 | **~2.6 MHz margin** — close; placement risk |
| vs stub-in Fmax 23.46 | **Impossible** without path cut / nostub |
| Ratio clk_ddr/sys | **3.0 exact** (cleaner edge family than 25/90 — still **STA required**) |

**Neither A nor B is applied in tree until parent grants fit + CDC STA plan accepted.**

---

## 3) DDR CDC — related clocks; 25 MHz is **not** free

### From SDC (quoted)

`sys_top.sdc` — **one** exclusive group for **all** `*|pll|…|divclk` (sys + sdram + ddr together):

```
set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|... }] \
   ...
```

`Plex.sdc` L9–11:

> general[0] (clk_sys 20 MHz) and general[2] (clk_ddr 90 MHz) share one set_clock_groups -exclusive group in sys_top.sdc, so STA applies a **related-edge relationship of 5.556 ns** across this intentional async path.

Narrow false_path only (`*async_fifo*mem*` → `*async_fifo*rd_data_r*`). **Do not** cut whole general[0]↔general[2]. **Do not raise clk_ddr.**

### Same PLL

STA clock table (t7b & nostub): both general[0] and general[2] derive from **same** `general[0].gpll~FRACTIONAL_PLL|vcoph[0]` (shared VCO). Changing out0 **changes edge phase vs out2**.

### Edge arithmetic (method validated: 20/90 → min Δ = 5.555556 = half ddr = STA comment)

| f_sys | f_ddr | Min positive related Δ (sample) | vs t7b CDC data delay class ~3.7–4.9 ns |
|-------|-------|----------------------------------|----------------------------------------|
| 20 | 90 | **5.555556 ns** | Matches STA; slack was **+0.333** class on binding half-cycle |
| **25** | 90 | **2.222222 ns** | **Likely negative** if data delay stays ~3.7+ ns |
| 30 | 90 | **11.111111 ns** (3:1) | Different family; same-edge/hold risks — **STA required** |

### Verdict

**unknown — STA required** whether any 25/90 or 30/90 product bump keeps CDC setup/hold green.  
**Analysis predicts 25 MHz sys + 90 MHz ddr *tightens* the worst setup relationship from ~5.56 ns to ~2.22 ns** — high risk of HARD_FAIL even with nostub Fmax 32.59 on *intra*-sys paths.  
**No new `set_false_path` to “make it close.”**

Raising **clk_sys alone** does **not** change the physical half-cycle *ddr* period, but because clocks are **related**, STA does **not** keep the old 5.56 ns relationship. Freeze-class logic (`ddr_frame_store` bank swap / fill FSM) sits on this CDC — three fits already lost to freeze class.

---

## 4) Gate re-run (direct `true rc=`, this session)

| Gate | true rc | Notes |
|------|---------|--------|
| `make define-parity` | **0** | |
| `make quartus-sv-subset` | **0** | |
| `tests/unit/test_ddr_frame_store_scanout_freeze.sh` | **0** | REPRO broken + PASS good; TB executed |
| `tests/unit/test_ddr_frame_store_scanout_shear.sh` | **0** | stride_fault REPRO; product_slow/fast CLEAN |
| `make unit` (PRODUCT_NO_STUB active) | **2** | Expected: product-default gate RED |
| `ALLOW_PRODUCT_NO_STUB_ACTIVE=1` product_no_stub test | **0** | Fit-mode allow works |
| `make unit` after QSF comment restore | *(re-run below)* | |

**PLL bump not in RTL** — freeze/shear exercise current 20 MHz sim timebase; they do **not** prove 25 MHz silicon.

---

## 5) Throughput arithmetic @25 MHz (still holds on paper)

Parent numbers:

| Clock | Budget cy/MB | Measured | Result |
|-------|--------------|----------|--------|
| 20 MHz | 2,667 | 2,965.8 | **MISS** ×1.11 |
| **25 MHz** | **3,334** | 2,965.8 | **PASS ~12%** |

- Arithmetic: 3334/2965.8 ≈ 1.124 → **~12% margin** — **HIT** if decode work still counted in **clk_sys cycles** at the new rate.  
- **Product pixels today:** ARM decode + DDR present; fabric `decode_stub` dark under `DDR_FRAME_STORE`. **25 MHz does not change ARM decode fps.**  
- **Fabric-decode research** is what consumes the cy/MB budget; needs either nostub+path-cut or stub path cut for STA at 25, **plus** CDC close.  
- Other period-sensitive pieces: any FSM timed in absolute ns vs HDMI/scanout remains on other clocks; **sys-domain** counters scale with period.

---

## 6) Pre-registration (if parent grants fit later)

**Baseline options — do not mix:**

| Baseline | ALM | M10K | DSP | clk_sys Fmax | clk_ddr setup class |
|----------|-----|------|-----|--------------|---------------------|
| t7b stub-in `8fdf440f` | ~23.5k class | 465 class | 44 class | 23.46 | +0.333 @ 5.556 rel |
| nostub `c74c6863` | **14,354** | **197** | **43** | **32.59** | +0.559 class |
| parent c5382bee-class | ~21,095 | 465 | 74 | unknown here | unknown |

**Predicted cargo for a *product* 25 MHz attempt (recommendation):**

1. **`PRODUCT_NO_STUB=1` + ALLOW=1** (required so limiter 23.46 path is absent).  
2. **PLL out0 = 25.000 MHz**, out2 = 90 **fixed**.  
3. **No new false_path.**  
4. **Expect:** ALM/DSP/RAM ≈ nostub baseline ± noise (PLL-only).  
5. **clk_sys Fmax:** still ≥25 if intra-sys limiter stays ≥32 class — **HIT if ≥25, MISS if regresses**.  
6. **CDC setup:** **PREDICT MISS or tight** at 25/90 (rel ~2.22 ns) unless data path shortens — **publish actual slack**.  
7. **Alternative worth STA compare:** **30 MHz sys / 90 ddr** (3:1) may have *better* related setup than 25/90 — pre-register both if slot allows multi-corner (usually one fit).  
8. Freeze + shear gates green on RTL before request; parent scores glass after BUILD_OK.

**Do-not-ship:** `9eb1431a`, `ff2e3ca3`, `f0d3a385`, `2890baac`, banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}`. Working reference core per parent: `c5382bee`. Nostub playback-verified: `c74c6863` (P2 PASS, **P1 unmeasured**).

---

## 7) User-facing answer (short)

- **Now:** clk_sys **20 MHz**, clk_ddr **90 MHz** (`pll_0002.v`).  
- **Default product still maps dark `decode_stub`** → measured Fmax sys **23.46 MHz** (~17% headroom).  
- **Nostub product** (`PRODUCT_NO_STUB`, RBF `c74c6863`) Fmax sys **32.59 MHz** — leaves ~63% vs 20 MHz run rate **if that config ships**.  
- **25 MHz would pass the cy/MB paper gate (~12% margin)** but **default stub-in fails STA at 25**, and **even nostub must re-close a tighter sys↔ddr related CDC (~2.22 ns vs 5.56 ns) — unknown without STA; do not raise clk_ddr.**  
- ao486-class is already matched on **ddr 90**; jtcores masters often 48/96 — we are low on **sys**, not ddr.

---

## 8) Fit request status

**NOT requesting a slot yet.** Blockers:

1. CDC at 25/90 predicted to tighten — need parent accept risk or prefer 30/90 STA experiment.  
2. Product default vs nostub must be an **explicit** fit cargo choice.  
3. Freeze gate green on current RTL (done); **not** a substitute for post-fit freeze + glass.  
4. QSF restored to product-default commented `PRODUCT_NO_STUB`.
