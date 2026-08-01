# SDC false_path justification — async_fifo mem→rd_data_r

**Status:** FLAGGED → **JUSTIFIED ON RECORD** (source-quoted). Not cleared by silicon;
parent may still demand a fit-time CDC check. No exclusive fit requested.

## Exact constraint (Plex.sdc:19-21)

```
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]
```

## What is cut

| Side | Keeper pattern | Clock domain | Role |
|------|----------------|--------------|------|
| FROM | `*async_fifo*mem*` | `wr_clk` | FIFO storage array write port |
| TO   | `*async_fifo*rd_data_r*` | `rd_clk` | Registered read-data output |

Instances (dominant product path): `ddr_bus_arbiter.m1_rsp_fifo` and every other
`async_fifo` (inventory #16 input_fifo, #22/#23 m1_dout path, #30 if present).

## What is NOT cut

- Gray pointer synchroniser flops (`rd_gray_w1/w2`, `wr_gray_r1/r2`)
- Binary counters `wr_bin` / `rd_bin`
- Full/empty combinational flags
- Any non-FIFO path between `general[0]` (clk_sys 20 MHz) and `general[2]`
  (clk_ddr 90 MHz), e.g. `fstore` `DDRAM_ADDR` — those remain timed

## Proof both ends are properly synchronised (async_fifo.sv)

### Write side (wr_clk) — mem write + gray publish
```
// async_fifo.sv:65-67
mem[wr_bin[AW-1:0]] <= wr_data;
wr_gray <= wr_gray_next;   // bin2gray(wr_bin_next)
```

### Read side (rd_clk) — two-flop sync of wr gray, then mem sample
```
// async_fifo.sv:81-86
wr_gray_r1 <= wr_gray;
wr_gray_r2 <= wr_gray_r1;          // 2FF sync wr→rd
if (rd_has_entry) begin
  rd_data_r <= mem[rd_bin[AW-1:0]]; // sample AFTER pointer says entry exists
  rd_gray <= rd_gray_next;
end
```

### Empty/full use only synchronised gray, never raw cross-domain binary
```
// async_fifo.sv:38-43
wire wr_full_now  = (wr_gray == wr_gray_full); // wr_gray_full from rd_gray_w2
wire rd_has_entry = (rd_gray != wr_gray_r2);   // wr_gray_r2 is 2FF-synced
```

### Inverse path (rd gray → wr) also 2FF
```
// async_fifo.sv:62-63
rd_gray_w1 <= rd_gray;
rd_gray_w2 <= rd_gray_w1;
```

### Gray code helper
```
// async_fifo.sv:34-35
function automatic [AW:0] bin2gray(input [AW:0] b);
  bin2gray = (b >> 1) ^ b;
```

This is the classic dual-clock Gray-pointer async FIFO. The **control** CDC is
the gray pointer 2FF chains. The **data** path `mem[]→rd_data_r` is intentionally
asynchronous: a location is only read after the read side observes the write gray
indicating that location is valid (and is not re-written until the write side
observes the read gray releasing it). STA cannot time that multi-cycle
occupancy contract as a single related edge.

## Why false_path rather than clock-group split

`sys_top.sdc` places `general[0]` and `general[2]` in one
`set_clock_groups -exclusive` group (same-group → related-edge STA at 5.556 ns
for 90 MHz). Measured:

| Fit | setup slack mem→rd_data_r | note |
|-----|---------------------------|------|
| ac90b155 | +0.502 (data delay 4.111) | passed by luck of placement |
| ff2e3ca3 | −0.233 (data delay 4.892); hold −0.517 | HARD_FAIL; hold relationship 0.001 ns is related-edge artifact |

Quartus 17.0 has **no** `set_max_delay -datapath_only`. Options:
1. Cut only FIFO data keepers (this constraint) — preserves timing on real
   same-group synchronous paths.
2. Split clock groups entirely — would also untime `fstore` DDR address path
   etc. **Rejected** in SDC comment.

## Stuck bank-swap class

A stuck bank swap is a **sys-clk** control bug (swap_pending NBA / prep recycle),
not an async_fifo data-plane CDC miss. Evidence path: `ddr_frame_store.sv`
`SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC` (907e5950) on `clk`, not on `clk_ddr` FIFO
data. False_path on FIFO data does not mask that class.

## Inventory cross-ref

`docs/cdc-crossing-inventory.md`:
- #16 `input_fifo` data clk→clk_ddr — SAFE (Gray async_fifo)
- #22 `m1_dout` clk_ddr→clk_sys — SAFE (fixed 3c6d1d2, Gray async_fifo)
- Module section documents Gray coding for all `async_fifo` instances

## Residual risk (honest)

- false_path means STA will **not** catch a future edit that samples `mem[]`
  without the gray empty check. Review gate: any change to `async_fifo.sv` read
  enable must keep `rd_has_entry` as the sole qualifier for `rd_data_r <= mem[...]`.
- Multi-bit `mem` word is not gray; metastability on a partially updated word is
  prevented by the pointer protocol (write completes before gray publish; read
  after gray observe), not by STA.

## Decision

**KEEP** the false_path. Reasoning is on record with file:line quotes. Do not
broaden to whole clock-group. Do not remove without replacing with an equivalent
Quartus-17-legal async datapath exception.
