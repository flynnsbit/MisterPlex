# DDR bandwidth / latency budget for fabric decode — **MODEL**

> **LABEL: UNMEASURED MODEL until parent runs PLXP counters on device.**  
> `DEVICE_BW_VERIFIED=0` until a hardware PLXP snapshot is published.  
> Do not treat any number below as silicon fact.

## Inputs (quoted / derived)

| Item | Value | Source |
|---|---|---|
| 720p I420 frame | 1,382,400 B | `ddr_frame_layout` / p720 arithmetic |
| Frame write @24 fps | ≈ 33.2 MB/s | 1382400×24 |
| Raster | 28.8 MHz, H=1600, V=750, 24.000 Hz | parent (shared PLL 720 MHz) |
| Scanout read (I420 present) | ≈ 33.2 MB/s average | one full frame / frame-time |
| clk_ddr | 90 MHz (nominal) | `pll_0002` product path |
| Avalon data width | 64-bit = 8 B/beat | f2sdram bridge |
| Peak theoretical stream | 90e6 × 8 = **720 MB/s** | wire rate if never stalled |
| DE10 DDR3 shared w/ HPS | 1 GB | board |

## Efficiency derating (**model**)

Real multi-master + refresh + HPS + short bursts never hit wire rate.

| Assumption | Factor | Rationale |
|---|---:|---|
| Controller+refresh+HPS floor | 0.45–0.60 of wire | industry ballpark for shared HPS DDR; **unverified here** |
| Useful fabric window (mid) | **≈ 0.50 × 720 = 360 MB/s** | **MODEL midpoint** |
| Conservative window | **≈ 0.40 × 720 = 288 MB/s** | design-against number |

## Reserved traffic (**model** @720p24)

| Client | MB/s | Notes |
|---|---:|---|
| Scanout read m0 | 33.2 | hard-RT |
| Frame write (ARM or fabric recon) | 33.2 | display DPB bank push |
| PLXP / misc | < 1 | mailbox |
| **Subtotal fixed** | **≈ 67** | |
| **Residual for MC/DPB (mid 360)** | **≈ 293 MB/s** | MODEL |
| **Residual (conservative 288)** | **≈ 221 MB/s** | **design-against** |

@30 fps scale fixed display traffic ×1.25 → residual ≈ 204 MB/s conservative.

## MC latency budget (**model**)

Decoder dies on **latency**, not average MB/s.

| Metric | Model target | Notes |
|---|---|---|
| Mean cmd→first-data | **< 40 clk_ddr cycles** (≈ 444 ns @90 MHz) | cache miss path |
| p99 / bin5 (128+) | **rare** under load | watch PLXP lat_bin5 |
| m0 grant delay | ≤ MAX_BURST beats (contract) | see arb contract |
| Tolerable MC stall before pipe bubble | depends on MB pipeline depth | w-clock / w-osd |

Ref-window cache (w-nostub) should absorb row-local reuse so DDR sees **bursts ≥ 4–8 beats** when possible. `single_cmds / rd_cmds` in PLXP is the fragmentation KPI.

## How parent falsifies this model

1. Fit with `DDR_PERF_COUNTERS=1` (no `FABRIC_FRAME_DMA`).
2. Run SSH recipe in `docs/ddr-perf-counters.md` during:
   - idle present only
   - 720p playback (ARM write + scanout)
   - (later) fabric MC hammer
3. Compute from snapshot:
   - `rd_MBps`, `wr_MBps`, stall fraction `stall/cycles`
   - `lat_mean = lat_sum/lat_n`, hist bins, `mean_burst = burst_sum/rd_cmds`
4. Set `DEVICE_BW_VERIFIED=1` only with quoted PLXP numbers + conditions.

If measured residual ≪ 200 MB/s or lat_bin4/5 dominate under MC-like traffic, **resize cache / reduce refs / lower MC issue rate** before claiming fabric decode headroom.
