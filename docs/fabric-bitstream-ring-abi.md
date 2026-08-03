# Fabric bitstream ring ABI (w-mem)

## Why

Parent measured ARM→bank CPU stores at **88.045 MiB/s structural** (bank outside
kernel System RAM → `/dev/mem` uncached always). Full-frame I420 push at 720p
(~1.38 MB) costs ~15 ms and kills the 41.667 ms decode budget.

Pushing the **H.264 bitstream** instead (~2585 kbit content → ~13.5 KB/frame @24)
costs ~**0.15 ms** at 88 MiB/s. ARM does HTTP+demux only; fabric owns decode+pixels.

## Published map (low → high)

| Region | Phys | Notes |
|--------|------|--------|
| Ring data | `0x30100000` .. `0x30140000` | 256 KiB power-of-two |
| PLXB CTRL | `0x30140000` | ARM producer count + epoch |
| PLXR READ | `0x30140008` | FPGA consumer count |
| PLXE ERR  | `0x30140010` | underrun/overrun sticky |
| STAT0..6  | `0x30140018` .. | level, seq, session, flags |
| Gap | `0x30140050` .. `0x30180000` | do not place producers |
| Option-C banks | `0x30180000` stride `0x180000` | I420 720p |
| Doorbell | `0x3047F000` | PLXK / bank select |
| Headroom | `0x30480000` .. `0x30600000` | triple / prefetch |
| PL330 | `0x30600000`+ | w-path scratch+staging |

Compile-time fences: `ddr_frame_layout.hpp` + `ddr_bitstream_ring.hpp` +
`ddr_frame_layout_params.svh`.

## Framing (PLXN)

32-byte LE header per record:

| Off | Field |
|-----|--------|
| 0 | magic `PLXN` |
| 4 | Event (Begin/Nal/Flush/End/Pause/Resume) |
| 5 | nal_type (Nal only) |
| 8 | session_id u64 |
| 16 | seq u32 (Nal continuity) |
| 20 | payload_len u32 |
| 24 | reserved 0 |

**Ordering (device memory):** store header+payload bytes, then publish absolute
producer byte count in PLXB. FPGA never reads past published count → no partial
record. Uncached mapping makes store order the friend; no dcache clean on product path.

## Backpressure / underrun

| Side | Full ring | Empty ring |
|------|-----------|------------|
| ARM | `PushResult::Full` — stop push, do not overwrite | n/a |
| Fabric | n/a | sticky underrun; **do not emit garbage pixels** — hold last good / black + flag |

Skipped Nal seq → desync sticky (honest fail). Partial publish (header without payload) → underrun, not silent splice.

## Fabric DDR BW (theoretical; not device-measured)

Peak f2sdram: 90 MHz × 8 B = **720 MB/s**.

| Client @720p | 24 fps | 60 fps |
|--------------|-------:|-------:|
| Bitstream ring RD | ~0.32 MB/s | ~0.32 |
| Decode ref RD (×1.5) | ~49.8 | ~124.4 |
| Recon write | ~33.2 | ~82.9 |
| Scan-out RD | ~33.2 | ~82.9 |
| **Combined** | **~116.5** | **~290.6** |
| % of peak | 16% | 40% |

Fits under half of theoretical peak at 60 with mid ref traffic. **Real efficiency
and ARM contention are unmeasured** — parent post-fit only. Worst ref_factor≈2
@60 → ~332 MB/s (46% peak) still arithmetic-OK; glitch risk is arbiter latency
not average BW.

## Files

- `host/libmisterplex/ddr_bitstream_ring.hpp` — map, PLXN pack, `BitstreamRingModel`
- `host/libmisterplex/ddr_frame_layout.hpp` + `fpga/.../ddr_frame_layout_params.svh`
- `fpga/.../ddr_bitstream_reader.sv` — existing FPGA consumer (product path)
- `tests/unit/test_bitstream_ring_abi.cpp` — collision + NEG seq/wrap

## Default

Product path unchanged. Fabric H.264 decode ingest remains behind existing stream
enable; this lane freezes ABI + unit model only (no Quartus).
