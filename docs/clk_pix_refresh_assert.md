# Falsifiable refresh assertion (w-clock) — 30 MHz product

## Why not 29.7 MHz
Quartus 17.0.2 Fitter rejected `output_clock_frequency = 29.7 MHz` on
`pll_0002` integer-N `altera_pll` (cited legal value **30 MHz**). Shared VCO with
clk_sys=20 / clk_ddr=90 cannot divide to 29.7 (no integer C).

## Product glass
| clk_pix | H×V | fps_eff | fps_x10 (period) |
|--------:|----:|--------:|-----------------:|
| **30.0 MHz** | 1650×750 | **24.242424…** | **≈242** |
| 29.7 MHz (illegal) | 1650×750 | 24.000 | 240 |
| 20.0 MHz (trap) | 1650×750 | ≈16.162 | ≈162 |
| ALT 28.8 MHz | 1600×750 | 24.000 exact | 240 |

A/V skew vs true-24 content at product: **+0.606 s/min** (+10101 ppm).

Exact-24 at 30 MHz needs HT×VT=1_250_000=2^4×5^7 — **no** H>1280 V>720 pair (verified).

## Measure
Gray free-run counters in clk_pix + **VSync period** in clk_sys:
`fps_x10 = (SYS_HZ × 10) / period_sys` → separates 240 vs 242 (frame count over 1 s cannot).

## Predicate
| Verdict | Condition |
|---------|-----------|
| **PASS_242HZ_PRODUCT** | fps_x10 ∈ **[241,244]** + valid + fps_ok + pix_ok |
| **EXACT24_NOT_PRODUCT** | fps_x10 ∈ **[238,240]** |
| **FAIL_16HZ_TRAP** | fps_x10 ∈ **[150,170]** |

## Parent device
```bash
./scripts/check_clk_pix_refresh.sh
# Expect: clk_pix_meas_verdict=PASS_242HZ_PRODUCT
```
