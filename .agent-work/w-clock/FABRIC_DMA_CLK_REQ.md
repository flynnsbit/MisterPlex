# Fabric DMA — clock / CDC requirements (w-clock)

Parent Sweep 118: ARM busy-spin is fixed; **ARM `/dev/mem` copy is not**.  
`T_copy_arm = 14.978 ms/frame` > decode headroom `8.962 ms` → **serial deficit ~6.0 ms**.  
Strategic path **(b) fabric DMA** retires all 14.978 ms (ARM never touches the frame bank).

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

## Non-claims

- Overlap path (a) unproven — parent experiment.
- e2e 720p24 **not** closed.
- Fabric DMA **not** implemented by this note alone.
