# fabric_ddr_writer — interface card (w-mem ↔ w-clock ↔ w-scaler)

Status: RTL module + Verilator TB landed; **not** instantiated in product
(`FABRIC_DDR_WRITER` macro default OFF in `Plex.qsf`).

## Ownership split (avoid fit merge conflicts)

| Lane | Owns | Does **not** touch |
|------|------|---------------------|
| **w-mem** | `fabric_ddr_writer.sv`, Option-C bank ABI, doorbell write ordering, pixel-source stream contract | scanout timing, content-window scaler math |
| **w-scaler** | content-window **read** path, runtime-coded window regs | DDR write master, doorbell issue |
| **w-clock** | multi-pixel present datapath, clk_sys scanout budget | bank fill, doorbell |

## Pixel-source contract (producers → writer)

```
src_valid / src_ready
src_data[63:0]     // planar I420 qwords: Y plane, then U, then V
src_frame_start    // high with first beat of frame
src_bank           // 0/1 sampled on first accepted beat
```

Producers (idle painter, test pattern, future fabric decode) must emit **full
coded-canvas I420** in bank order. Native content smaller than canvas is a
producer concern (pad or coordinate PLXG native_push v2) — writer does not scale.

## DDRAM master contract

- Clock: **clk_ddr** (90 MHz product).
- Write-only; `DDRAM_RD=0`.
- Address is **qword** address (`phys[31:3]`), same as `ddram_frame_rd`.
- Payload then **drain fence** then **one** doorbell write:
  - `DIN[31:0] = PLXK (0x504C584B)`
  - `DIN[63:32] = {bank, format[1:0]=2'b01, seq[28:0]}`
- Parameters: `PHYS_BASE`, `HPS_BANK_STRIDE_BYTES`, `DOORBELL_PHYS` (base may move).

## Arbiter integration

Product `ddr_bus_arbiter` stays 2-master (untouched). Additive `ddr_bus_arbiter3`
+ `fabric_ddr_attach` provide m2 for the writer:

| Master | Role | Priority when bus free |
|--------|------|------------------------|
| m0 | frame-store present RD | highest (cmd wins) |
| m2 | fabric_ddr_writer WE | next (`m2_want` = writer busy) |
| m1 | bitstream RD | lowest |

**Do not** steal m1. Outstanding depth = 1 WE is enough for 720p30 (~5.8% of
90 MHz) if grant share ≥ ~6%. Sustained fabric→DDR3 BW: unknown until fit +
parent measure.

## Rate (evidence from TB print)

- 720p24: 33.18 MB/s → bus_frac ≈ 4.6%
- 720p30: 41.47 MB/s → bus_frac ≈ 5.8%
- rate_closes=1 with outstanding_depth=1 (no shared-bus model in TB)

## Ship gate (host)

`ddr720p24ShipAcceptsZeroArmPerPixel` requires `publish_bytes=0` — fabric writer
is the path that makes that true.

## Parent iomem (2026-08-02)

Option-C `0x30180000` / `0x3047F000` **parent-verified** inside `memmap=513M$511M` reserved window.
Headroom ≈251.5 MB. Prefer deeper banks/prefetch over cramped layouts. Triple-buffer map constants
exist (`kPlex720pMapBytes3Bank`); doorbell still 1-bit bank until frame-store widens.

## Plex.sv top wire (default OFF)

When `FABRIC_DDR_WRITER=1` (QSF commented by default):
- Product `ddr_bus_arbiter` is replaced by `ddr_bus_arbiter3` + `fabric_ddr_attach`
- Idle FSM on `clk_ddr` paints bank0 then bank1 with internal I420 pattern after reset
- **Stops while `has_frame` (CDC 2FF)** so ARM playback banks are not stomped
- Default bank ABI = **product 480p** (`0x30000000` / stride `0x80000` / doorbell `0x300FF000`) so glass works without w-scaler
- `FABRIC_DDR_WRITER_720P=1` switches attach to Option-C 720p (needs scaler read path)

Integration fit recipe: uncomment the `FABRIC_DDR_WRITER` macro + the five SV files in `Plex.qsf`. Do not enable 720P until w-scaler lands CODED 1280 read.
