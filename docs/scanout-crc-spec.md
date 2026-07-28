# Scanout CRC Specification — for w-osd / w-a3

**Author:** w-c1 (spec only; implementation is w-osd or w-a3 scope)
**Date:** 2026-07-27
**Purpose:** Enable remote visual verification of the FPGA present path without
HDMI capture hardware.

## Problem

The DDR frame CRC (`verify_ddr_frame_crc.sh`) proves ARM→DDR write correctness
but says nothing about what exits the FPGA's HDMI output. Between DDR and the
user's screen, the following transforms occur:

1. DDR read (via `ddr_frame_store`, using `clk_ddr` bank arbitration)
2. YUV→RGB colour conversion (BT.601 matrix, full/limited range)
3. Upscaling / pillarbox (640×480 presented from 618×480 crop of 624×480 coded)
4. Blanking (HBlank, VBlank, colour bars in DE region)
5. HDMI encoding (via MiSTer framework `sys_top.v` / `ascal`)

A CRC at the scanout point (after step 3, before step 5) verifies the entire
FPGA-internal present path with one number.

## Specification

### Interface

```systemverilog
module scanout_crc #(
    parameter RESET_EACH_FRAME = 1  // 1 = per-frame CRC; 0 = running
)(
    input  wire        clk,          // CLK_VIDEO (= clk_sys = 20 MHz)
    input  wire        ce_pix,       // pixel clock enable (10 MHz effective)
    input  wire        VBlank,       // vertical blank (active high)
    input  wire        HBlank,       // horizontal blank (active high)
    input  wire [7:0]  R, G, B,     // RGB output from present_core
    output reg  [31:0] frame_crc,    // CRC-32 of the last complete frame
    output reg         frame_crc_valid, // pulse: frame_crc updated
    output reg  [19:0] pixel_count   // pixels counted in last frame
);
```

### Signals (from `Plex.sv` / `present_core`)

These already exist at the top level or in `present_core` outputs:
- `VBlank`, `HBlank`: from `present_core` (directly drives `sys_top` via framework)
- `R`, `G`, `B`: 8-bit RGB output from the present core's YUV→RGB conversion
- `ce_pix`: pixel clock enable (divides `clk_sys` by 2 for non-scandoubled)
- `CLK_VIDEO`: same as `clk_sys` (20 MHz)

### Behaviour

1. On rising edge of `VBlank` (frame complete):
   - Latch `crc_accumulator` → `frame_crc`
   - Latch `pixel_counter` → `pixel_count`
   - Pulse `frame_crc_valid` for one `clk` cycle
   - Reset `crc_accumulator` to `32'hFFFFFFFF`
   - Reset `pixel_counter` to 0

2. On each `ce_pix` while `!VBlank && !HBlank` (active pixel):
   - Feed `{R, G, B}` (24 bits) into CRC-32 accumulator
   - Increment `pixel_counter`

3. CRC polynomial: IEEE 802.3 (`0x04C11DB7`, reflected, init `0xFFFFFFFF`,
   final XOR `0xFFFFFFFF`). This matches `cksum` / `crc32` utilities.

### Readback

Route `frame_crc` and `pixel_count` into the existing `status_telem_r` mailbox
(or a dedicated HPS register). The ARM reads it via mmap. **Do not use SPI** for
this — the mailbox is already polled at ~10 Hz by misterplexd.

Suggested mailbox slot: repurpose unused bytes in `status_telem_r[159:128]` or
add a second 128-bit telemetry latch (the HPS bridge has capacity).

### Resource estimate

- **ALMs:** ~40–60 (CRC logic + counter + latch)
- **M10K:** 0
- **DSP:** 0
- **Registers:** ~85 (32 CRC + 32 latch + 20 counter + valid)

### Verification

The scanout CRC is deterministic for a given frame store content + geometry +
colour matrix. Therefore:

1. Write a known frame to DDR (via `verify_ddr_frame_crc.sh`)
2. Wait one VBlank
3. Read `frame_crc` from mailbox
4. Compare against pre-computed golden CRC (computed offline from the same
   frame data through the same YUV→RGB + pillarbox pipeline in Python)

### What this covers that DDR CRC does not

| Defect class | DDR CRC | Scanout CRC |
| --- | --- | --- |
| ARM decode wrong | ✅ | ✅ |
| DDR write corrupt | ✅ | ✅ |
| DDR read wrong bank (frozen screen) | ❌ | ✅ |
| YUV→RGB matrix wrong (601/709) | ❌ | ✅ |
| Range wrong (full/limited) | ❌ | ✅ |
| Crop/pillarbox misaligned | ❌ | ✅ |
| Present reads stale data | ❌ | ✅ |
| HDMI encoding corrupt | ❌ | ❌ (need grabber) |

### What this does NOT cover

- HDMI PHY / encoding issues (signal integrity, TMDS)
- Display-side interpretation (TV processing, overscan)
- Audio output

### Priority

Lower than bank-release fix. But once deployed, it eliminates the need for a
physical HDMI grabber for **all decode correctness and present-path verification**
except HDMI-PHY-level issues. This is a permanent remote test capability.
