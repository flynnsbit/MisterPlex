# BUILD_OK — fit-nostub-chrome (PRODUCT_NO_STUB + plex_chrome)

**Lane:** w-fit · **Branch:** `w-fit-ceiling-fd-min` · **Cargo HEAD:** `aa565f0d`  
**Fit slot:** `fit-nostub-chrome`  
**RBF path:** `fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.rbf`  
**RBF md5:** `c74c6863a56ad0d9ef4a24e28af8b7e2`  
**Prefix8:** `c74c6863` — **not** in do-not-ship / banned set  
`{c5382bee,9eb1431a,ff2e3ca3,f0d3a385,2890baac,8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}`

**Baseline (deployed live core):** `8fdf440f` = `remote_out/fit-t7b-prog480/`  
ALM 23,585 · M10K 465/553 · DSP 44 · clk_ddr +0.333 · clk_sys +0.793 · pll_hdmi +0.669

---

## Actual fit resources (from `Plex.fit.rpt`)

| Metric | Actual | Baseline t7b | Δ |
|--------|-------:|-------------:|--:|
| ALM | **14,354 / 41,910 (34%)** | 23,585 | **−9,231** |
| M10K (RAM blocks) | **197 / 553** | 465 | **−268** |
| Block memory bits | 872,913 | (t7b) | |
| DSP | **43 / 112** | 44 | **−1** |
| Negative-slack rows | **0** | 0 | 0 |

**Hierarchy (fit.rpt entity scan):**
- `decode_stub`: **0 hits** (removed)
- `dpb_mem`: **0 hits** (removed with stub)
- `plex_chrome:u_plex_chrome`: **present** — 5.3 ALM, 54 mem bits, **0 M10K**
- `ddr_frame_store`: present
- `ascal`: present

**Chrome M10K finding (evidence, not guess):**  
`sys_top.v` ties `.list_we(1'b0)` for this glass-only fit. Map report: `list_a[*]` **Stuck at GND due to stuck port clock_enable**. BOOT_DEMO constant-folds `list_b[0]=#` into logic.  
⇒ Chrome **did not consume the +12 M10K prereg** (MISS → 0). Glass `#` path is constant/logic, still valid for parent 1080p bbox score.  
**Product PLXC write path is not connected in this fit** — follow-up before daily-driver ship if ARM list load is required.

**M10K free for future plane growth:** 553−197 = **356 free** (was 88). Matches PRODUCT_NO_STUB −268 reclaim exactly.

---

## STA (from `Plex.sta.rpt` Setup/Hold Summary) — TNS=0 all domains

| Clock | Setup slack | Hold slack | Fmax | Baseline setup | Δ setup |
|-------|------------:|-----------:|-----:|---------------:|--------:|
| `clk_ddr` general[2] 90 MHz | **+0.559 ns** | +0.386 | 97.43 MHz | +0.333 | **+0.226** |
| `clk_sys` general[0] 20 MHz | **+0.982 ns** | +0.246 | **32.59 MHz** | +0.793 | **+0.189** |
| `pll_hdmi` | **+0.587 ns** | +0.211 | 162.73 MHz | +0.669 | −0.082 |
| `pll_audio` | +14.920 | +0.259 | 38.82 | | |

`make post-fit-timing STA_RPT=.../Plex.sta.rpt` → **true rc=0**  
`make post-fit-hierarchy FIT_RPT=.../Plex.fit.rpt` → **true rc=0**  
No negative setup/hold/recovery/removal/min-pulse.  
**No new `set_false_path`** (timing exclusion audit PASS in fit log).

`clk_sys` Fmax **23.46 → 32.59 MHz**: matches JOB1 claim that intra-sys critical path was dark `decode_stub` MV logic.

---

## Pre-registration vs actual (FROZEN table)

| Metric | Predicted | Actual | Verdict |
|--------|-----------|-------:|---------|
| ALM | ~16.9k ±1k (15.9–17.9k) | **14,354** | **MISS low** (−~2.5k). Chrome folded to 5.3 ALM; stub reclaim ~full −9.2k |
| M10K | ~209 ±4 | **197** | **MISS low** (−12). Chrome +0 M10K (list_we tied 0); stub −268 exact |
| DSP | 44 | **43** | **MISS −1** (stub DSP gone) |
| pll_hdmi setup | ≥ +0.20 ns | **+0.587** | **HIT** |
| clk_ddr setup | ≥ +0.25 ns | **+0.559** | **HIT** |
| PRESENT_PROFILE ledger | FLAT | (parent scores; RTL n/a) | parent |

Misses are **favorable area** except they flag chrome RAM elision for product PLXC.

---

## Pre-fit gates (this cargo; true rc direct)

| Gate | true rc |
|------|--------:|
| `test_telem_flags_abi.py` self + check | 0 |
| `test_product_no_stub_dark_silicon.sh` ALLOW=1 | 0 |
| `make define-parity` | 0 |
| `make quartus-sv-subset` | 0 |
| `make unit` (subset used) | 0 |
| `test_ddr_frame_store_scanout_freeze.sh` | 0 |
| `test_ddr_frame_store_scanout_shear.sh` | 0 |
| `test_ddr_frame_store_scanout_colour.sh` | 0 |
| `test_ddr_frame_store_scanout_sustained.sh` | 0 |
| `run_verilator.sh` PINNOTFOUND/%Error → rc=2 | in force |
| post-fit-timing | 0 |
| post-fit-hierarchy | 0 |
| remote fit compile | 0 |

---

## Telem ABI

`PRODUCT_NO_STUB` ties `stub_busy=0` (bit kept). Width 8 MSB-first unchanged. Gate `bc70ad1f` red-before-green parent-verified.

---

## BUILD_OK criteria

| Check | Result |
|-------|--------|
| Fit rc=0 | YES |
| Negative STA | **NO** (all ≥0, TNS=0) |
| RBF md5 banned/do-not-ship | **NO** (`c74c6863…`) |
| decode_stub absent | YES |
| plex_chrome present | YES |
| M10K headroom for OSD | **356 free** (was 88) |

## BUILD_OK = YES (fabric compile + STA)

**Not a product PASS.** Parent deploys `DEPLOY_LOAD=menu` once and scores **viewed pixels at 1080p**:
- `#` glyph bbox **32×32 ±1** (body_scale=4 from HDMI_HEIGHT)
- H-runs %4 == 0
- Telemetry is not evidence

**Agent does not deploy.**

---

## Risks / follow-ups

1. **Chrome list RAM elided** (`list_we=0` + BOOT_DEMO). Glass OK; product PLXC needs live write ports before claiming full plane.
2. Binding `clk_ddr` half-cycle CDC class remains (slack improved +0.559, not removed).
3. Bit-identity UNVERIFIED (intentional new design).
4. BOOT_DEMO is fit-time glass aid only.
