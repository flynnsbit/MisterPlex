# Overnight DDR Writeback — FPGA Glass Path

## Architecture

The FPGA H.264 decode core (`h264_decode_core`) produces reconstructed I420
macroblocks through its `dpb_wr_en/addr/data` interface. Previously these writes
went nowhere (`dpb_write_base=0`, no DDR write path).

This commit adds `fpga_ddr_writeback.sv` — a byte-to-qword bridge that:

1. **Accumulates** sample-at-a-time DPB byte writes into 64-bit DDR qwords.
2. **Writes** qwords to the same DDR bank layout that `ddr_frame_store` reads
   (I420 planar at `PHYS_BASE=0x3000_0000`, two banks with stride
   `DDR_FRAME_YUV420P_BANK_STRIDE`).
3. **Rings the PLXK doorbell** on `frame_done` so `ddr_frame_store` triggers a
   bank swap on the next vsync — identical to what the ARM host does.
4. **Double-buffers**: alternates writes between bank 0 and bank 1.

## Wiring

```
stream_path
  └── h264_decode_core
        ├── dpb_wr_en/addr/data  ──────────┐
        └── frame_done           ──────────┤
                                           ▼
                                 fpga_ddr_writeback
                                           │ ddr_want/we/addr/din
                                           ▼
                              ┌── m1 priority mux ──┐
                              │                      │
                       stream_path DDR rd      wb DDR wr
                              └──────┬───────────────┘
                                     ▼
                              ddr_bus_arbiter m1
                                     │
                              ddr_frame_store (m0, reader)
                                     │
                                  DDRAM_*
```

The writeback shares the arbiter's m1 port with the bitstream stream reader.
A priority mux in `Plex.sv` gives writes priority (they are rare — one qword
per 8 samples at decode rate).

## host_owns_fs Policy

Previously, once the host ARM wrote any frame via F1/DDR, `host_owns_fs` latched
permanently, suppressing all FPGA diagnostic paint and (now) FPGA glass.

Fixed: `fpga_glass_swap` (asserted on `frame_done`) **clears** `host_owns_fs`,
allowing FPGA-decoded frames to own present. If the host ARM later writes a
frame, it reclaims ownership. This creates a natural dual-source mux:
- ARM active → host owns present
- ARM idle + FPGA decoding → FPGA owns present

## Open Glass Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `dpb_write_base` is still 0 — the writeback adds `PHYS_BASE` in hardware, but the DPB address space must match ddr_frame_store's `CODED_W×CODED_H` I420 layout exactly | High | Requires decode core to use the same geometry (624×480 coded) |
| Partial qword writes — if an MB's last byte doesn't land on a qword boundary, the remaining bytes stay in the accumulator until the next write or frame_done | Medium | In practice, 16×16 luma + 8×8×2 chroma = 384 bytes = 48 qwords exactly; but row-strided writes may leave partial qwords between lines |
| No back-pressure from DDR busy to decode core — if DDR is slow, accumulator could miss writes | Low | DDR write BW >> decode rate (one sample per clk vs DDR at 90 MHz×64 bits) |
| Bank race — if ARM and FPGA both ring doorbell in the same frame | Medium | The `host_owns_fs` mux ensures only one source at a time; ARM should not write while FPGA stream is active |
| Deblock filter not implemented — reconstructed pixels lack loop filtering | High | Visual quality will show blocking artifacts; functional for glass-test |

## Files Changed

- `fpga/Plex_MiSTer/rtl/fpga_ddr_writeback.sv` — NEW: byte→qword DDR writer + doorbell
- `fpga/Plex_MiSTer/rtl/stream_path.sv` — export `decode_dpb_wr_*` and `decode_frame_done`
- `fpga/Plex_MiSTer/Plex.sv` — instantiate writeback, m1 priority mux, fix `host_owns_fs`
- `tests/rtl/fpga_ddr_writeback_tb.sv` — NEW: unit test for accumulator + doorbell
- `docs/overnight-ddr-writeback.md` — this file

## Glass-Test Procedure (for parent)

1. Build with `DDR_FRAME_STORE=1` (already the product macro set).
2. Deploy RBF. Do NOT start misterplexd (no ARM frame writes).
3. Feed an H.264 elementary bitstream via F3 ioctl.
4. Observe: decoded frames should appear on HDMI after the first slice is
   fully reconstructed (I-frame or P-frame with reference).
5. Verify `ddr_doorbell_ok` rises in OSD status (confirms PLXK doorbell accepted).
6. Verify `frames_written` counter increments (visible via extended status or RTL sim).
