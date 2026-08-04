# clk_pix refresh + raster assert (device-checkable)

## Why shared 29.7 MHz failed (root cause)

Quartus 17.0.2 Fitter rejected `output_clock_frequency = 29.7 MHz` on
`pll_0002` `general[3]` (shared with clk_sys=20 / clk_ddr=90). Cause is the
**shared integer-N VCO**, not string formatting:

- VCO must be a multiple of `lcm(20,90)=180` MHz.
- `180k / 29.7` integer ⇒ `k` multiple of 33 ⇒ **min VCO = 5940 MHz** (Cyclone V
  fPLL VCO ~600–1600: out of range).
- Quartus suggested **30 MHz** (VCO=900 family works with 20/90) — that yields
  `fps_eff = 24.242…` (+1.01% judder). Exact-24 at 30 MHz needs
  `HT×VT=1_250_000=2^4×5^7` — **zero** pairs with H>1280 and V>720.

## Product fix: dedicated `pll_pix`

| Clock | Source | Hz | Glass @ H1650×V750 |
|-------|--------|-----|---------------------|
| **clk_pix** | **dedicated `pll_pix`** VCO=1485 C=50 | **29.700000 MHz** | **24.000 exact** |
| shared-30 trap | do not ship | 30.0 MHz | 24.242… |
| same-clock trap | clk_sys | 20.0 MHz | 16.16… |
| VIC-4 60 (out of scope) | dedicated C=20 | 74.25 MHz | 60.000 |

M/N/C: `M=297 N=10` → VCO=`50×297/10=1485` MHz (in range); C=50 → 29.7.

## Measure (not a photograph)

`fps_x10 = (SYS_HZ × 10) / period_sys` from observed VSync period separates
240 vs 242. Plus per-frame raster totals (rd-duck):

| Check | Expect |
|-------|--------|
| CE/frame | 1_237_500 |
| lines/frame | 750 |
| CE/line | 1650 |
| DE/frame | 921_600 |
| DE/line (active) | 1280 |
| active lines | 720 |
| underrun Δ | 0 |

## Verdicts

| Verdict | Predicate |
|---------|-----------|
| **PASS_240HZ_PRODUCT** | fps_x10 ∈ **[239,241]** + valid + fps_ok + pix_ok + ce_ok + de_ok + **raster_ok** |
| **FAIL_SHARED30_TRAP** | fps_x10 ∈ **[242,244]** (30 MHz residual — do not ship) |
| **FAIL_16HZ_TRAP** | fps_x10 ∈ **[150,170]** |
| **FAIL_RASTER_ADVERSARIAL** | fps may look OK but `raster_ok=0` (e.g. H1375×V900) |

## Parent device command

```bash
./scripts/check_clk_pix_refresh.sh
# or after ≥2s warm-up:
# ssh root@$MISTER_HOST /media/fat/linux/set_status --raw
# Expect: clk_pix_meas_verdict=PASS_240HZ_PRODUCT
```

Stills cannot distinguish 16.16 / 24.000 / 24.242. **Never score glass from a frame grab alone.**

## PLL budget

Design baseline: 3 PLLs (main fabric, pll_hdmi, pll_audio). Product with
`PRESENT_CLK_PIX_PLL` adds `pll_pix` → **4**. Device resource from a real fit
report: `Total PLLs ; 3 / 6 ( 50 % )` (Plex.fit.rpt) ⇒ **6 PLLs available** on
`5CSEBA6U23I7`. Headroom: 2. STA of the new domain is **UNKNOWN until parent fit**.
