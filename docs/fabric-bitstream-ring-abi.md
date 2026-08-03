# Fabric bitstream ring ABI (w-mem)

## Why

Parent measured ARM→bank CPU stores at **88.045 MiB/s structural** (bank outside
kernel System RAM → `/dev/mem` uncached always). Full-frame I420 push at 720p
(~1.38 MB) costs ~15 ms and kills the 41.667 ms decode budget.

Pushing the **H.264 bitstream** instead is effectively free. Parent scored **real
PMS output** `real720p_2600k.mp4` (maxBR=3100, 1440 frames, prereg 4/4 HIT):

| AU size | Bytes | Push @88.045 MiB/s |
|---------|------:|-------------------:|
| mean | 13,506.6 | **0.146 ms** |
| min | 413 | negligible |
| **MAX keyframe** | **60,915** | **0.660 ms** |
| decoded I420 | 1,382,400 | 14.97 ms |

Even the worst keyframe is **22.7× smaller** than one decoded frame and **0.66 ms
vs a 41.667 ms deadline**. Sustained ingest ~0.32 MB/s = 0.35% of the ceiling.
Bitstream-across-boundary is effectively free — **proven**.

### Role in the plan (parent correction 2026-08-03 — read this)

Full fabric H.264 decode is **NOT** the near-term 720p path. w-path header-level
audit + w-clock MB-rate arithmetic independently show existing RTL is a partial
intra/MB datapath (~20% of a decoder), not a stream decoder; calendar **8–16 weeks**
and no credible Cyclone V path to the clocks a full decode would need.

**Near-term architecture that survives all parent sweeps:**
1. PMS Constrained Baseline 1280×720 @~2585k — PROVEN
2. **ARM decodes** 35.94 ms/f vs 41.667 — PROVEN (+5.73 ms)
3. Frame reaches Option-C bank **without CPU store** — OPEN (w-path PL330 DMA)
4. Fabric present/scale/overlay native 720p — in flight (needs `clk_pix` ≠ `clk_sys`)
5. ARM never touches scale/overlay/idle — fabric lanes

This ring ABI remains the **multi-month endgame** ingest path (ARM=HTTP+demux,
fabric=decode) and stays default-OFF / non-blocking. Near-term critical path is
**DMA → Option-C banks** (`0x30180000`, doorbell `0x3047F000`), not bitstream→fabric
decode. Do not staff this ring as if it unblocks 720p glass this week.

## Published map (low → high)

| Region | Phys | Notes |
|--------|------|--------|
| Ring data | `0x30100000` .. `0x30140000` | 256 KiB power-of-two; ≥3× worst AU (60915+32) |
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

## Worst-AU headroom (measured)

- `kMeasuredWorstAuBytes = 60915` (parent, real stream — not nominal bitrate)
- `kWorstAuRecordBytes = 60947` (PLXN header + payload)
- `kMinWorstAuSlots = 3` → ring must hold ≥3 worst-case records (**182841 B**)
- 256 KiB floor capacity = **4** worst-case records (`kRingWorstAuCapacity`)
- Producer backpressure: `ringHasWorstAuHeadroom(level)` before starting an AU
- **Do not shrink the ring below 3× worst AU** without a new parent measurement

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


## Stream profile (parent 2026-08-03)

Measured PMS delivery for our 720p path:

- **Constrained Baseline**, level 3.1, 1280×720, yuv420p, 24 fps
- `has_b_frames = 0` (I,P,P,P… only)
- Entropy: **CAVLC** (no CABAC)

Parent measured the stream subset (CAVLC, no B-frames). CABAC is absent in tree
and not required for that stream. **Module filenames are not capability** —
`h264_decode_top` is a pre-parsed coeff recon engine, not annex-B in (w-path
`a16439fe`). Gate still refuses High/CABAC so a future decoder never sees garbage.

### Compatibility gate (this ABI)

`Event::Begin` carries:

| Byte | Field |
|------|--------|
| 6 | `profile_idc` (66 = Baseline) |
| 7 | flags: `b0=constraint_set1`, `b1=cabac` |

`isFabricDecodeCompatible()` accepts Baseline (66) without CABAC only.
High/Main/CABAC → **Fatal refuse** (no silent garbage). w-path owns pinning the
PMS request; this gate is the ring-side last line of defence.


## Near-term vs endgame (do not confuse)

| Path | Status | Owner |
|------|--------|--------|
| CPU I420 → bank | DEAD (88 MiB/s structural) | — |
| PL330 DMA → Option-C bank | **critical path / OPEN** | w-path |
| Fabric present/scale @720p | in flight; needs clk_pix | w-scaler/osd/clock/nostub |
| Bitstream ring → fabric decode | **endgame, 8–16 weeks** | future; ABI frozen here |
