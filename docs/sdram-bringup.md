# SDRAM bring-up (B1)

MiSTerPlex now drives the single MiSTer SDRAM stick instead of tying the pins off.  The pinout comes from the upstream MiSTer template `sys/sys.tcl` single-stick `SDRAM_*` assignments already sourced by `Plex.qsf`; `sys/sys_dual_sdram.tcl` remains unused because the lab unit has one stick.

`fpga/Plex_MiSTer/rtl/sdram.sv` is vendored from MiSTer-devel NeoGeo:

- URL: <https://github.com/MiSTer-devel/NeoGeo_MiSTer/blob/227d4f418fd908a66712329400a6f619ca4fee77/rtl/mem/sdram.sv>
- License: GPL-3.0-or-later, per the file header.
- Local adaptation: synthesis macro `SDRAM_CL2` selects CAS 2; default CAS is 3 for the clock sweep.

## Clock sweep macros

The default SDRAM PLL output is 100 MHz.  Define one of these Quartus Verilog macros for sweep variants: `SDRAM_CLK_110`, `SDRAM_CLK_120`, `SDRAM_CLK_133`.  `Plex.sv` also adjusts the refresh toggle interval for the selected clock.

## Memory test

`rtl/sdram_memtest.sv` runs after reset and destructively tests the detected address range:

1. alias probe for 16/32/64 MB as visible through the standard controller;
2. walking-one pattern across every 16-bit word;
3. walking-zero pattern across every 16-bit word;
4. address-derived uniqueness pattern across every 16-bit word.

## HPS DDR mailbox

The SDRAM result is published without SPI at physical address `0x3007F110`, next to the existing `PLXS` mailbox and away from W-A01's `0x3007F108` input mailbox.

64-bit little-endian layout:

| Bits | Field |
|---|---|
| `[31:0]` | magic `0x504C584D` (`PLXM`) |
| `[39:32]` | sequence counter |
| `[43:40]` | state: 1 init, 2 detect, 3 walk1, 4 walk0, 5 address, 6 pass, 7 fail |
| `[47:44]` | size code: 0 unknown, 2 = 16 MB, 3 = 32 MB, 4 = 64 MB |
| `[63:48]` | saturated error count |

The mailbox is published on change and heartbeat by `rtl/ddram_frame_rd.sv`.
