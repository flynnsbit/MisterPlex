# clk_pix 29.7 MHz STA PRE-REG (w-clock)

**Status:** PRE-REGISTERED before fit. Not a measurement. Fit is exclusive (w-fitgate).

## Baseline (parent-measured, nostub-poststrip1, clk_pix OFF)

| Clock | Slack | TNS |
|-------|------:|----:|
| `emu\|pll\|...\|general[2].gpll...\|divclk` (clk_ddr 90) | **+0.311 ns** | 0.000 |
| `pll_hdmi\|...\|counter[0]...\|divclk` | +0.571 ns | 0.000 |
| `emu\|pll\|...\|general[0].gpll...\|divclk` (clk_sys 20) | +1.290 ns | 0.000 |

Control: parent read of artifact `.../remote_out/nostub-poststrip1/` STA Setup Summary.

## What changes in this candidate

- `PRESENT_CLK_PIX_PLL=1` → emu PLL `number_of_clocks(4)`, `outclk_3 = 29.700000 MHz`
- `Plex_clk_pix.sdc` creates `clk_pix` and `set_clock_groups -asynchronous` vs sys/ddr/hdmi
- MULTI PPC=2 present path + `CLK_VIDEO = clk_pix`
- clk_sys stays **20 MHz** (no CLK_SYS_24)

## PRE-REGISTERED predictions (publish before fit)

### P1 — clk_pix Fmax / setup on general[3]

- **Prediction:** Restricted Fmax on `general[3]` **≥ 29.7 MHz** with **slack ≥ 0.000 ns** (hard fail if negative).
- **Confidence:** LOW–MED. No prior fit of outclk_3 on this netlist. Path is new.
- **If miss:** quote failing path endpoint; do not deploy. Options: keep rate_match @20+PPC2 without clk_pix, or reduce MULTI logic on pix domain.

### P2 — clk_ddr thin path (+0.311) under new place

- **Prediction:** clk_ddr worst setup **≥ 0.000 ns** (may drop below +0.311 due to re-place).
- **Soft target:** ≥ +0.150 ns. Below 0.000 = HARD FAIL.
- **Rationale:** async clock groups should isolate clk_pix from clk_ddr *timing edges*, but placement density from MULTI+linebufs can still erode ddr routes. **Not claiming** clk_pix “eats” the +0.311 path directly — claiming re-fit risk.

### P3 — clk_sys

- **Prediction:** clk_sys slack **≥ +0.5 ns** (was +1.290). Still positive.

### P4 — hold

- **Prediction:** hold TNS = 0.000 on sys/ddr/pix. If hold fails on pix CDC, fix synchroniser — do not multicycle-lie.

## What would settle each claim

```text
make post-fit-timing STA_RPT=<fit>/output_files/Plex.sta.rpt
make post-fit-timing-margin STA_RPT=...
# Quote Fmax Summary rows for general[0], general[2], general[3]
```

## NOT claimed

- Fitted Actual MHz of outclk_3 (Quartus may pick different M/N/C; recipe documents exact integer solutions).
- Device refresh until parent runs refresh check (see `scripts/check_clk_pix_refresh.sh`).
- T_copy +8.962 ms margin — still **PRE-REGISTERED arithmetic only**, e2e OPEN until fabric DMA measured.
