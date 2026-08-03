# fabric_ddr_writer — interface card (w-mem ↔ w-clock ↔ w-scaler)

Status: RTL + credit + attach + Verilator TBs landed; **not** product-default
(`FABRIC_DDR_WRITER` macro remains commented OFF in `Plex.qsf`).

## Ownership split (avoid fit merge conflicts)

| Lane | Owns | Does **not** touch |
|------|------|---------------------|
| **w-mem** | write path, Option-C ABI, `fabric_bank_credit`, doorbell order, pattern producer | scanout timing, content-window scaler math |
| **w-scaler** | content-window **read** of the same banks, runtime coded window | DDR write master, doorbell issue |
| **w-clock** | multi-pixel present datapath, clk_sys scanout budget | bank fill, doorbell |
| **w-path** | ARM/PL330 external producer into free banks | fabric credit RTL (consumes contract) |

## Bank credit contract (write ↔ read)

Module: `fabric_bank_credit.sv` · host mirror: `fabric_bank_credit.hpp`

| Signal | Meaning |
|--------|---------|
| `free_mask[i]=1` | producer may fill bank *i* |
| `claim_req/ack` | exclusive take of one free bank |
| `commit_pulse` + `commit_bank` | payload+doorbell done → `swap_pending`, `free_mask=0` |
| `vsync_swap` | pending → disp; old disp bit set free; `frames_done++` |

Product PLXD layout (hi word): `free[1:0] | disp<<2 | swap<<3 | frames<<16`.
PLXD phys = doorbell + `0x128` → Option-C `0x3047F128`.

**Corruption class (rd-duck):** never write a bank while free bit is clear
(scanout may be mid-read). After commit, free_mask stays 0 until vsync frees
the previous display bank. Attach drops claim when `produce_en` deasserts so
a late claim cannot steal the bank freed by vsync.

## Pixel-source contract (producers → writer)

```
src_valid / src_ready
src_data[63:0]     // planar I420 qwords: Y plane, then U, then V
src_frame_start    // high with first beat of frame
src_bank           // 0/1 sampled on first accepted beat
```

Internal producer: `fabric_i420_pattern_src` — Y ramp + `frame_phase` scroll
(visible motion). External path reserved for PL330/decode bridge (w-path).

## DDRAM master contract

- Clock: **clk_ddr** (90 MHz product).
- Write-only; `DDRAM_RD=0`.
- Address is **qword** address (`phys[31:3]`), same as `ddram_frame_rd`.
- Payload then **drain fence** then **one** doorbell write:
  - `DIN[31:0] = PLXK (0x504C584B)`
  - `DIN[63:32] = {bank, format[1:0]=2'b01, seq[28:0]}`
- Parameters: `PHYS_BASE`, `HPS_BANK_STRIDE_BYTES`, `DOORBELL_PHYS`.

## Option-C ABI (parent-verified iomem)

| Field | Value |
|-------|------:|
| base | `0x30180000` |
| bank stride | `0x00180000` |
| bank1 | `0x30300000` |
| doorbell | `0x3047F000` |
| 720p I420 | 1_382_400 B |

Inside `memmap=513M$511M`; nothing claimed in `/proc/iomem` @ 0x3xxxxxxx.

## Arbiter integration

Product `ddr_bus_arbiter` stays 2-master when macro OFF (bit-identical path).
`ddr_bus_arbiter3` + attach when ON:

| Master | Role | Priority when bus free |
|--------|------|------------------------|
| m0 | frame-store present RD | highest |
| m2 | fabric_ddr_writer WE | next (`m2_want`) |
| m1 | bitstream RD | lowest |

## Rate (TB evidence)

- 720p24: 33.18 MB/s → bus_frac ≈ 4.6% @ 90 MHz × 8 B
- 720p30: 41.47 MB/s → bus_frac ≈ 5.8%
- Sustained fabric→DDR3 BW on device: **unknown — parent measures after fit**

## Plex.sv top wire (default OFF)

When `FABRIC_DDR_WRITER=1`:
- Default bank ABI = **Option-C 720p**
- `FABRIC_DDR_WRITER_480P=1` → product 480p banks (`0x30000000` / `0x80000` / `0x300FF000`)
- Continuous `produce_en = !has_frame` (2FF CDC); ARM playback not stomped
- `vsync_swap` from VSync falling edge (clk_ddr); credit only acts if `swap_pending`
- `(* keep *)` on WE + free_mask + frames_done + phase so fit cannot prune

## Integration fit recipe (parent)

Uncomment in `Plex.qsf`:
```
VERILOG_MACRO FABRIC_DDR_WRITER=1
SYSTEMVERILOG_FILE rtl/fabric_ddr_writer.sv
SYSTEMVERILOG_FILE rtl/fabric_i420_pattern_src.sv
SYSTEMVERILOG_FILE rtl/fabric_ddr_write_path.sv
SYSTEMVERILOG_FILE rtl/fabric_ddr_attach.sv
SYSTEMVERILOG_FILE rtl/fabric_bank_credit.sv
SYSTEMVERILOG_FILE rtl/ddr_bus_arbiter3.sv
SYSTEMVERILOG_FILE rtl/fabric_luma_linebuf.sv
```
Optional bring-up without w-scaler: also `FABRIC_DDR_WRITER_480P=1`.

## Parent measure commands (post-fit)

```bash
# hierarchy must show non-zero rows (not optimised away)
make post-fit-hierarchy FIT_RPT=...   # expect fabric_ddr_attach, fabric_bank_credit,
                                      # fabric_ddr_writer, ddr_bus_arbiter3

# glass: moving Y ramp, ARM idle (no cast). Capture via helper only:
scripts/hdmi_capture_idle.sh /path/to/frame.png
# score: ACTIVE non-black, phase motion across frames; daemon must not DDR-push
```

## Ship gate (host)

`ddr720p24ShipAcceptsZeroArmPerPixel` requires `publish_bytes=0` — fabric-written
banks are the path that makes that true. Pattern is fit/bring-up proof, not ship.

## Async producer (PL330 / HPS) — shared with w-path

Ordering (absolute): **credit → fill (chunks OK) → payload_visible → ONE doorbell**.

| Module | Role |
|--------|------|
| `fabric_bank_credit.sv` | free_mask, filling_mask, visible_mask; sticky `err_doorbell_before_visible` |
| `host_bank_ingest_credit.sv` | w-path scoreboard twin on free_mask + doorbell/retire |
| `bank_producer_order.hpp` | host unit scoreboard (same phases as `ddr_zero_copy_ingest.hpp`) |

Internal pattern writer still uses claim → fill+drain → `commit_pulse` (doorbell already ordered in `fabric_ddr_writer`).

External path ports on credit: `ext_payload_visible_pulse`, `ext_doorbell_pulse`.

NEG test: `./tests/unit/test_fabric_bank_credit_async_verilator.sh`

## Option-C bank alignment facts (geometry only)

| Addr | role | mod 1MiB | mod 2MiB |
|------|------|----------|----------|
| `0x30180000` | bank0 | `0x80000` | `0x180000` |
| `0x30300000` | bank1 | `0` | `0x100000` |

**Parent incident 2026-08-03:** bank-address copy A/B (~15 vs ~21 ms), bank-sweep
table, and `pl330_dma_ms_per_frame=23.839` were measured under a **rogue remote
CPU burner** left after a hung control experiment — **RETRACTED**. DMA "sustained"
arm also invalid (poll-iteration counter → impossible 136 GB/s). Stand down on
anomaly chase until parent clean re-measure.

**Clean numbers that survive (parent):** decode alone mean **35.94 ms/f** (margin
5.73 ms @24fps). Any concurrent ARM peer still blows the deadline in clean runs
tested so far. Route A under real full-frame DMA: **unmeasured**. Fabric
zero-ARM path remains the robust ship route and the fit milestone.
