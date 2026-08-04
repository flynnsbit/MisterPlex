# w-mem: ddr_frame_dma as publication engine on reconcile

Branch: `w-mem-frame-dma-integ` (base `origin/reconcile/main-2026-08-04`)
SHA: (see git)

## M10K layout correction (parent handbook — recheck)

Parent invalidated “1280 B = 1 M10K” / bits÷10240 packing. Cyclone V legal modes
max width **40b**; **64b is not native**.

| Prior claim (WRONG) | Corrected EST | Layout assumed | Control |
|---|---:|---|---|
| bounce 128×64 = 8192b → **1** M10K | **2** M10K | 2× parallel (typ. 256×32 each), depth 128 of 256 | nostub-poststrip1 entity: `line_buf_ram` DATA_W=64 yram 4992b→**2** M10K; uram 2496b→**2** M10K (width-bound) |
| arb3 m1 FIFO ≤1 M10K | **2** M10K EST | same 64b width class, AW=3 shallow | same width-bound control (entity row for this FIFO not yet in a FABRIC_FRAME_DMA fit) |

**Budget total unchanged:** parent fit M10K 197/553 free **356**; ALM free **27_556**.
What changed is how far 356 goes for 64-bit path engines.

Entity fit of `ddr_frame_dma` itself: **UNVERIFIED** (no product fit with FABRIC_FRAME_DMA=1).

## Delivered

| Module | Role | M10K | depth×width layout | ALM |
|---|---|---:|---|---|
| `ddr_frame_dma` | staging→bank COPY | **2 EST** | 128×64 → 2×(256×32) | ~300–500 EST |
| `ddr_bus_arbiter3` | m0>m2>m1 + Q=8 | **2 EST** | m1 FIFO 8×64 class | ~400–600 EST |
| `ddr_frame_base_mux` in store | present base select | **0** | combinational | ~20 EST |
| `ddr_publish_copy_budget` | PL330 vs fabric PREREG | **0** | n/a | 0 |
| **Path total (DMA on)** | | **~4 EST** | | ~700–1100 EST |

## Hierarchy wire (integration-ready)

- `files.qip`: dma, base_mux, arbiter3, geom, job, budget, width_check
- `Plex.sv` under `FABRIC_FRAME_DMA` (default **OFF** in QSF):
  - `u_frame_dma` + `ddr_bus_arbiter3` (replaces 2-port arbiter)
  - start = status[12] CDC edge; bank=status[13]; src=`DDR_FRAME_DMA_STAGING_PHYS` (0x30601000)
- Product path unchanged when macro undefined (2-port `ddr_bus_arbiter`)

## PRE-REG then MEASURE (controls)

| Pin | PRE-REG | MEASURE (ideal phys TB) | Control |
|---|---:|---:|---|
| T_copy_arm | 14978 µs | (host Sweep9; not remeasured) | parent archive |
| T_ideal solo | 3840 µs | **3967 µs** scaled | G0 rc=0 |
| T_with_present | 5760 µs | **4620 µs** @~6.25% present duty | G1 rc=0 ratio 80% |
| Margin vs ARM | — | **10358 µs** | G1 beats arm |
| FAULT max_deny | >>48 | **491** | REPRO_OK |
| CWE quantum deny | ≤48 | **1** | G1b |
| bounce M10K | **2** (was 1) | layout EST only | static + budget TB |

**DEVICE_BW_VERIFIED=0** — check is parent fit + HDMI capture after enable.

## Contention (load-bearing)

Arbitration: **m0 present > m2 publish > m1 bitstream**; `M2_QUANTUM_BEATS=8`.
Quantum requires holding `m0_rd` while busy (CWE). FAULT sticky twin max_deny=491.

Port math (NOT device): peak 90 MHz×8 B = 720 MB/s ideal.
720p24 present RD 33.1776 + COPY R+W 66.3552 ≈ **99.53 MB/s ≈ 13.8%** ideal peak.
TB contended copy ~4.62 ms vs ARM 14.978 → arithmetic margin ~10.4 ms (w-clock +8.962
path assumes fabric retires T_copy). **Still sim-only.**

## PL330 cross-check (honest)

| Route | M10K | T EST | Contends present f2sdram | Contends HPS CPU |
|---|---:|---:|---|---|
| Fabric DMA | **2** | 3.84 ideal / 5.76 PRE-REG cont / **4.62 meas TB** | YES | no |
| PL330 | **0** | 9.216 @150MB/s EST | no | YES (MiSTer spin) |
| Dyn-base reader | **0** | 1.92 present-R only | present is the reader | no |

**VERDICT_PREREG:** On time, contended fabric beats PL330 EST (4.6–5.8 < 9.2 ms) and ARM (14.978).
PL330 wins **M10K=0** and avoids f2sdram collision; device may reverse BW ranking.
Preferred zero-mover remains **dyn-base direct reader** when decode buffer is fabric-visible.
If PL330 device-proves ≥150 MB/s under MiSTer spin, it is a valid alternate with 0 M10K —
**lane would prefer that over its own 2-M10K engine** when dyn-base cannot apply.

## Negative cases

- G2 misalign → err_align
- FAULT sticky twin → present starve REPRO
- Static: FABRIC_FRAME_DMA on product QSF fails red twin
- Static: naive bits/10240 still equals 1; corrected PREREG must be 2

## OPEN

1. Device sustained BW under live present
2. status[12] shared with store doorbell kick — may need dedicated PLXG start bit
3. FABRIC_FRAME_DMA still default OFF until parent enables on integ fit
4. Entity-row M10K for `ddr_frame_dma` / arb3 FIFO after first FABRIC_FRAME_DMA fit
