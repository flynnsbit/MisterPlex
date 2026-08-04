# w-mem: ddr_frame_dma as publication engine on reconcile

Branch: `w-mem-frame-dma-integ` (base `origin/reconcile/main-2026-08-04`)
SHA: (see git)

## Delivered

| Module | Role | M10K | ALM |
|---|---|---:|---|
| `ddr_frame_dma` | staging→bank COPY engine | **1 EST** (bounce 128×64b=8192b) | ~300–500 EST |
| `ddr_bus_arbiter3` | m0>m2>m1 + Q=8 | ≤1 (m1 FIFO) | ~400–600 EST |
| `ddr_frame_base_mux` in store | present base select | **0** | ~20 EST |
| `ddr_publish_copy_budget` | PL330 vs fabric PREREG | **0** | 0 |

Budget control: parent post-strip **356 M10K / 27_556 ALM** free. DMA claims ~1–2 M10K.

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

**DEVICE_BW_VERIFIED=0** — check is parent fit + HDMI capture after enable.

## PL330 cross-check (honest)

| Route | M10K | T EST | Contends present f2sdram | Contends HPS CPU |
|---|---:|---:|---|---|
| Fabric DMA | 1 | 3.84 ideal / 5.76 PRE-REG cont / **4.62 meas TB** | YES | no |
| PL330 | **0** | 9.216 @150MB/s EST | no | YES (MiSTer spin) |
| Dyn-base reader | **0** | 1.92 present-R only | present is the reader | no |

**VERDICT_PREREG:** On time, contended fabric beats PL330 EST (4.6–5.8 < 9.2 ms) and ARM (14.978).
PL330 wins M10K=0 and avoids f2sdram collision; device may reverse BW ranking.
Preferred zero-mover remains **dyn-base direct reader** when decode buffer is fabric-visible.
If PL330 device-proves ≥150 MB/s under MiSTer spin, it is a valid alternate with 0 M10K.

## Negative cases

- G2 misalign → err_align
- FAULT sticky twin → present starve REPRO
- Static: FABRIC_FRAME_DMA on product QSF fails red twin

## OPEN

1. Device sustained BW under live present
2. status[12] shared with store doorbell kick — may need dedicated PLXG start bit
3. FABRIC_FRAME_DMA still default OFF until parent enables on integ fit
