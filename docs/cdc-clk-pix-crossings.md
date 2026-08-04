# clk_pix ↔ clk_sys / DDR crossings (720p present path)

**Owner:** w-mem  
**Branch:** `w-mem-clk-pix-cdc`  
**Trigger:** dedicated `clk_pix` PLL (w-clock) makes `clk_pix` truly async to
`clk_sys` / `clk_ddr` (no longer a sibling counter on the same VCO).  
**Fit:** none (this lane).  
**Macros (p720probe1 measured):** `PRESENT_MULTI_PIXEL=1`, `PRESENT_PX_PER_CLK=2`,
`PRESENT_CLK_PIX_PLL=1`. Default product leaves all OFF → no clk_pix domain.

## Clock domains (720p MULTI + PLL)

| Domain | Signal | Hz (recipe) | Source |
|---|---|---:|---|
| clk_sys | `clk` / `clk_sys` | 20_000_000 | `pll_0002` outclk_0 |
| clk_ddr | `clk_ddr` | 90_000_000 | `pll_0002` outclk_2 |
| clk_pix | `clk_pix` | 29_700_000 compact | outclk_3 **or** dedicated pll (w-clock) |
| clk_audio | `CLK_AUDIO` | 24_576_000 | external — out of scope here |

## Exhaustive crossing table (clk_pix involved)

Direction is **producer → consumer**.

| ID | Signal | file:line | Dir | Class | Mechanism | Verdict |
|---|---|---|---|---|---|---|
| P1 | group RGB+sync+lane pack (`W` bits) | `present_npx_path.sv:109-125` async_fifo ports; pack `present_npx_path.sv:77-89`; consume `present_npx_path.sv:188-197,256-288` | clk_sys → clk_pix | multi-bit data | `async_fifo` gray ptr + MLAB mem | **SAFE** — NOT multi-bit bit-sync |
| P2 | `prefill_go_sys` → `prefill_go_pix` | `present_npx_path.sv:134-165` (sys); CDC `present_npx_path.sv:168-179` `u_prefill_go_sync` | clk_sys → clk_pix | single-bit level | `cdc_sync_bit` STAGES=2 `preserve` | **SAFE** (was open 2FF regs; now preserve module) |
| P3 | `reset` → `mp_reset_pix` / `reset_pix` | `present_core.sv` `mp_rst_pix0/1` async-assert/sync-deassert (PRESENT_CLK_PIX_PLL) | clk_sys → clk_pix | reset | async assert + 2FF sync deassert `preserve` | **SAFE** (standard reset CDC; plain 2FF of reset level would miss POR) |
| P4 | `mp_out_fs` → `frame_start` (cadence) | `present_core.sv` `u_mp_fstart_cdc`; cadence sink `present_core.sv:162-172` `display_tick` | clk_pix → clk_sys | single-bit pulse | `cdc_pulse_toggle` | **FIXED** — was bare assign of pix pulse into sys cadence (**UNSAFE** under async PLL) |
| P5 | `ce_pix,H/V*,r,g,b` → MiSTer video | `present_core.sv` assigns `ce_pix`/`H*`/`r*` from `mp_out_*` (clk_pix); `Plex.sv` `CLK_VIDEO`/`CE_PIXEL`/`VGA_*` | clk_pix → framework | multi-bit + CE | **same-domain**: `CLK_VIDEO=clk_pix_pll` when MULTI+PLL | **FIXED** — was `CLK_VIDEO=clk_sys` while CE/RGB on clk_pix (**UNSAFE** open CDC into ascal/OSD) |
| P6 | `has_frame` into `in_lane_valid` | `present_core.sv` `mp_tq_lde… & has_frame` into npx `in_*` | clk_sys → clk_sys | level | same domain (store CDC already sys) | **SAFE** (not a clk_pix cross) |
| P7 | beam `mp_*` H/V/RGB into npx `in_*` | `present_core.sv` `u_mp_beam` + `mp_tq_*` → npx | clk_sys → clk_sys | multi-bit | same domain before FIFO | **SAFE** |
| P8 | ddr_frame_store `vsync_pulse` | `present_core.sv` `.vsync_pulse(fstart)` | clk_sys → clk_ddr (existing) | pulse/toggle | existing store CDC inventory #10 | **SAFE** — uses **sys** `fstart` from template/L4 beam, **not** `mp_out_fs` |
| P9 | line_buf_ram dual-port | `line_buf_ram.sv:1-26`; instances in `ddr_frame_store.sv` | clk_ddr ↔ clk_sys | multi-bit | true dual-clock M10K | **SAFE** — **no clk_pix port** |
| P10 | ddr_frame_store want_y / banks / input_fifo | `ddr_frame_store.sv` (see `docs/cdc-crossing-inventory.md` #1–17) | clk_sys ↔ clk_ddr | mixed | gray / 2FF / async_fifo | **SAFE** — **no clk_pix** |
| P11 | `clk_pix` tied unused on default | `present_core.sv` `_unused_keep_timing` includes `clk_pix` | n/a | n/a | default OFF | **N/A** product |

### Not crossings (same domain under MULTI+PLL)

- `present_beam_ppc` entire beam on `clk` (sys) — `present_core.sv` `u_mp_beam`
- skid buffer in `present_npx_path` — sys only
- unpack hold regs — pix only after FIFO

## Mechanisms (doctrine)

| Class | Required mechanism | Forbidden |
|---|---|---|
| single-bit control | `cdc_sync_bit` (≥2FF, `preserve`) | bare assign across clocks |
| single-bit pulse fast→slow | `cdc_pulse_toggle` or async_fifo | 1-cycle pulse sampled by slow clock |
| multi-bit data | `async_fifo` / gray ptr / req-ack stable data | **NOT multi-bit bit-sync** |
| dual-port RAM | `line_buf_ram` separate clocks | n/a |

## SDC

| File | Owner | Role |
|---|---|---|
| `Plex_clk_pix.sdc` | w-clock | clock names + `set_clock_groups -asynchronous` |
| `Plex_clk_pix_cdc.sdc` | w-mem | `set_max_delay`/`set_min_delay` on FIFO data + 2FF keepers; **no** blanket `set_false_path` on RGB/CE |
| `Plex.sdc` | product | existing sys↔ddr async_fifo false_path (related-edge artifact) — unchanged |

**w-clock request:** if dedicated `pll_pix` renames the STA clock path, update the
`$plex_clk_pix` string in **both** SDC files. Keep async groups; do not false_path
CE_PIXEL/VGA buses.

## Default-OFF behaviour

| Macro state | clk_pix domain? | CDC modules active? |
|---|---|---|
| all OFF (product) | no — `clk_pix` tied to `clk_sys` | npx not instantiated; CLK_VIDEO=clk_sys |
| MULTI only | no (same clock) | npx on; prefill 2FF still present (harmless latency); frame_start direct |
| MULTI + CLK_PIX_PLL | **yes async** | P1–P5 active; CLK_VIDEO=clk_pix_pll |

## Controls

| Test | Role | Expect |
|---|---|---|
| `tests/unit/test_present_npx_cdc_rtl_sim.sh` FAULT=0 | POS dual-clock bit-exact | rc=0 PASS G0 |
| same FAULT=2 | NEG multi-bit bit-sync tear | REPRO_OK tears>0 |
| same FAULT=1 | FAULT elab no-prefill-sync | REPRO_OK marker |
| `tests/unit/test_cdc_pulse_toggle_rtl_sim.sh` | POS pulse conserve + NEG bare | rc=0 |
| `tests/unit/test_clk_pix_cdc_static.py` | static wiring/SDC/inventory | rc=0 |

## M10K

`cdc_sync_bit` / `cdc_pulse_toggle`: **0 M10K** (FF only).  
`async_fifo` in npx: MLAB (`ramstyle="MLAB"`) → **0 M10K** (fit-measured analogue arbiter fifo).
