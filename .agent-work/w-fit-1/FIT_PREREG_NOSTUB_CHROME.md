# FIT PRE-REG — PRODUCT_NO_STUB + plex_chrome (FROZEN)

**Slot:** exclusive granted parent 2026-08-01  
**Branch:** w-fit-ceiling-fd-min  
**Baseline:** 8fdf440f / fit-t7b-prog480 — ALM 23585 · M10K 465 · DSP 44  
**pll_hdmi slack +0.669 · clk_ddr +0.333 · clk_sys +0.793**

| Metric | Predict | Miss if |
|--------|---------|---------|
| ALM | **~16.9k ±1k** | outside 15.5k–19.5k |
| M10K | **~209 ±4** (cap chrome +24) | free <300 or used >230 |
| DSP | **44** | rises |
| pll_hdmi setup | **≥ +0.20 ns** (hard ≥0) | negative = HARD_FAIL |
| clk_ddr setup | **≥ +0.25 ns** | < +0.20 |
| clk_sys setup | **≥ +0.793** | large drop |
| Hold all | ≥0 | negative |
| TNS | 0 | any |
| RBF md5 | not in do-not-ship | any banned |
| ledger | FLAT | movement = bug |

**Cargo:** PRODUCT_NO_STUB=1 · plex_chrome BOOT_DEMO=1 post-shadowmask · stub_busy tied 0  
**false_path:** none new  
**Win:** parent 1080p `#` bbox 32×32 ±1
