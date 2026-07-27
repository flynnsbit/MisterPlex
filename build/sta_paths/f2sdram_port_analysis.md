# f2sdram Port Availability — Can We Add a DPB Port?

**Author:** w-cap  
**Date:** 2026-07-27  
**Source:** `sys/sysmem.sv` at `a6b1124`

---

## Current f2sdram Configuration

The `cyclonev_hps_interface_fpga2sdram` hard IP is configured with:

### Command Ports (6 available, 3 used)

| Port | Width   | Type       | Role              | FPGA signal | Clock     |
|------|---------|------------|-------------------|-------------|-----------|
| 0    | 128-bit | read+write | Video scaler (ascal) | `vbuf`   | clk_100m  |
| 1    | 64-bit  | read+write | DDRAM (frame store + bitstream) | `ram1` | clk_ddr (90 MHz) |
| 2    | 64-bit  | read+write | ALSA audio DMA    | `ram2`      | clk_audio |
| 3    | —       | disabled   | —                 | —           | —         |
| 4    | —       | disabled   | —                 | —           | —         |
| 5    | —       | disabled   | —                 | —           | —         |

### Data Channels (4 available, ALL 4 used)

| Channel | Read FIFO | Write FIFO | Serving    |
|---------|-----------|------------|------------|
| 0       | FIFO 0    | FIFO 0     | vbuf low 64 bits  |
| 1       | FIFO 1    | FIFO 1     | vbuf high 64 bits |
| 2       | FIFO 2    | FIFO 2     | ram1 (DDRAM)      |
| 3       | FIFO 3    | FIFO 3     | ram2 (audio)      |

**The constraint is data channels, not command ports.** 3 of 6 command ports are
free, but all 4 read/write data channel pairs are consumed. The 128-bit vbuf
port uses two channel pairs (0+1).

## Answer: YES, a 4th port is possible. Here is how.

### Option A: Downgrade vbuf to 64-bit (RECOMMENDED)

Reduce the video scaler port from 128-bit to 64-bit, freeing channel pair 1.
Assign the new DPB port to the freed channel.

| Change | Detail |
|--------|--------|
| `cfg_port_width` | `10 01 01 00 00 00` → `01 01 01 01 00 00` |
| `cfg_cport_type` | Add `11` for port 3 |
| `cfg_cport_rfifo_map` | Map port 3 → FIFO 1 |
| `cfg_cport_wfifo_map` | Map port 3 → FIFO 1 (or read-only if DPB is read-only) |
| sysmem.sv | Add `ram3` port, `f2sdram_safe_terminator_ram3`, wire to HPS |
| sys_top.v | Expose `ram3_*` signals alongside existing `ram1_*`/`ram2_*` |

**Scaler bandwidth impact:** halved from 128b×100MHz=1.6 GB/s to 800 MB/s.
The MiSTer scaler (ascal) typically runs at 1080p60 = 1920×1080×4×60 = 497 MB/s
peak read+write, so 800 MB/s should be sufficient for standard modes. Some
high-refresh or 4K-passthrough modes could be affected.

### Option B: DPB port shares FIFO with ram1

Keep vbuf at 128-bit. Add port 3 mapped to FIFO 2 (same as ram1). The SDRAM
controller interleaves access. **Not recommended** — this adds contention on
the exact port we are trying to decongest, partially defeating the purpose of
a separate DPB port.

### Option C: Replace audio port (ram2) with DPB

Repurpose port 2 for DPB reads. Move audio DMA through the ram1 arbiter.
Audio bandwidth is minimal (~0.5 MB/s at 48kHz×16bit×2ch) so contention
impact is low. **Requires sys_top.v audio path changes** — moderate effort.

## Cost Summary

| Item | Impact |
|------|--------|
| Files changed | `sys/sysmem.sv`, `sys/sys_top.v`, `Plex.sv` |
| Qsys regeneration | **NOT required** — the `cfg_*` parameters are edited directly in the `cyclonev_hps_interface_fpga2sdram` instantiation |
| Bit-identity baseline | **Invalidated** — any HPS configuration change alters the bitstream. New baseline must be established. This is expected for an architectural change. |
| Framework departure | **YES** — `sysmem.sv` is a MiSTer framework file. This is a permanent fork of the sys layer. Other MiSTer cores (ao486, PSX) have done this. |
| FPGA fabric cost | Minimal — one additional `f2sdram_safe_terminator` instance (~50 ALMs) |
| New clock domain | The DPB port needs its own clock. If using `clk_ddr` (90 MHz), no new domain. If using a decode clock (45 MHz), adds another cross-domain boundary. |

## Recommendation

**Option A.** Downgrade vbuf to 64-bit and claim the freed channel for DPB.
The scaler bandwidth headroom is sufficient, no contention is introduced,
and the change is well-precedented in the MiSTer ecosystem.

If DPB is read-only (reference fetches only, no DPB writes through this port),
the write FIFO mapping for port 3 can be left unmapped, simplifying the design.
