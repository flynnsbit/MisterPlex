# w-clock STATUS — clk_sys 24 recommendation + apply

**branch:** w-clock-clksys24-rec  
**base:** 8609fd78  
**gates:** rtl-lint rc=0; unit rc=0; SKIP-NOT-PASS=2; define-parity rc=0

## Four bullets (CONFIRMED)
1. L4 on clk_sys @20 → ~20.005 Hz
2. Active 22.12 Mpix/s > 20
3. L4 ⊥ MULTI; clk_pix unused by L4
4. CLK_VIDEO=clk_sys

## HSync
Reviewer "already fixed" on 8609fd78: **REFUTED** (H_FP=32 → width 0). Parent STOP: not fixed here.

## Recommendation: (a) clk_sys→24
Applied default-OFF `PRESENT_CLK_SYS_24`. Reverted dead clk_pix PLL kit.

## PRE-REGISTER STA
- nostub-class Fmax≥24: PASS expected (prior ~32.59 residual_csum)
- stub-class ~23.46: FAIL @24
- unknown until parent fit

See CLKSYS24_ANALYSIS.md
