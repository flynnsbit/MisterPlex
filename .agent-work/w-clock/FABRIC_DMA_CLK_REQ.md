# Fabric DMA — clock / CDC requirements (w-clock)

Parent Sweep 118: ARM busy-spin is fixed; **ARM `/dev/mem` copy is not**.  
`T_copy_arm = 14.978 ms/frame` > decode headroom `8.962 ms` → **serial deficit ~6.0 ms**.  
Strategic path **(b) fabric DMA** retires T_copy CPU time without needing a second ARM core
(after pinned/coherent source — not “ARM never touches”).

## Terms (do not mix)

| Symbol | Value | Kind |
|--------|------:|------|
| R_req | 33.1776 MB/s/dir | **payload rate** |
| T_copy_arm | 14.978 ms/frame | **CPU time** (not a rate) |
| C_arm | 88.0 MiB/s | uncached copy throughput |
| clk_sys | 20 MHz | present / control (STA wall @24) |
| clk_ddr | 90 MHz | f2sdram / DDRAM port |
| clk_pix | 29.70 MHz | glass (MULTI recipe) |

## Clock domains for path (b)

1. **Ingest master** (new or extended): lives on **clk_ddr** (same as `ddr_frame_store` fill FSM) so bursts need no extra async to the DDRAM port.
2. **Doorbell / bank swap** control stays on **clk_sys** with existing toggle-snapshot CDC into clk_ddr (already in store).
3. **Present read** unchanged: linebuf on clk_sys extract, fill on clk_ddr.
4. **Do not** place a bulk DMA engine on clk_sys@20 — peak 8 B × 20 MHz = 160 MB/s theoretical but present PPC path + control already share it; keep bulk on clk_ddr@90 (720 MB/s model).

## Bandwidth after DMA (no ARM write to present bank)

If fabric only **reads** staging once and **writes** present bank once per frame (or present reads staging directly):

- Worst still ~**66 MB/s** payload R+W on f2sdram (same as today’s steady pair).
- **Removes** concurrent HPS CPU master fighting the same banks during copy — the deficit term is CPU time, not only bus beats.
- Real-reader steady delta already measured: payload **173120** beats/frame (+ door ~9k) @20:90 PPC2 — TB `test_ddr_frame_store_720p_ppc2_bus` (w-clock). w-osd may adopt; do not re-derive 624×48/1:1 as “full”.

## STA / SDC

- No new clk_sys overclock (Fmax stub-in 23.17; @24 FAIL).
- Any new DMA FSM: constrain on clk_ddr; false-path only for true async greys already proven.
- Fit PRE-REG P1–P9 unchanged until nostub netlist STA.

## Lane split

| Lane | Owns |
|------|------|
| w-mem | bank ABI, f2sdram master, zero-copy ingest RTL |
| w-path | ARM stop calling sendDdrFrame memcpy; measurement |
| w-clock | clocks, CDC, rate SoT, reader beat TB, no clk_sys@24 |
| w-nostub | ALM/M10K budget for DMA after reclaim lands |
| w-osd | full-frame present proof; may reuse w-clock bus TB |

## Frame budget PRE-REG after full T_copy retire (w-clock)

Inputs (parent-measured; w-clock arithmetic only, no device):

| Term | ms | Source |
|------|---:|--------|
| Frame budget @24 | 41.667 | 1000/24 |
| Decode | 32.705 | Sweep 116 |
| T_copy_arm | 14.978 | Sweep 118 |
| Serial deficit (decode+copy) | 6.016 | 14.978−8.962 |

**Prediction (IF fabric retires full 14.978 ms from ARM critical path AND decode stays
32.705 AND residual kick ≪ headroom):**

- ARM path becomes decode-only vs 41.667 → **margin +8.962 ms**
- **ARM decode-vs-budget CLOSES by 8.962 ms** (was 6.016 ms short serial)
- Swing = T_copy = 14.978 ms

**Does NOT claim:** product e2e 720p24 CLOSED, fabric_bw_closed, PPC2 delivery,
decode invariant under DMA, zero kick cost, reader deadline under concurrent fabric write.

Locked in `tests/fixtures/p720_bw_contract.json` → `t_copy_retire_prereg` and
`MISTERPLEX_BW_AFTER_COPY_RETIRE_MARGIN_US=8962`.

## Non-claims

- Overlap path (a): **INFEASIBLE under one effective ARM core** (parent 2026-08-04:
  MiSTer framework ~100% of one core at idle; mpx-main ~0.8%). Not a dual-core rescue.
- e2e 720p24 **not** closed (prereg is ARM serial decode budget only).
- Fabric DMA **not** implemented by this note alone.
- w-clock did **not** re-run the device `/proc/stat` capture (no device access).
