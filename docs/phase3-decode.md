# Phase 3 — FPGA decode path (research + plan)

## Goal

Move **decode off dual-A9 FFmpeg** for Profile MiSTerPlex-1 so ARM is protocol/demux only and **FPGA owns unique frames + present + audio FIFO**.

Phase 2 remains valid bootstrap: FFmpeg → `/dev/fb0` + `/dev/MrAudio`.

## Profile MiSTerPlex-1 (initial)

| Field | Target |
|-------|--------|
| Video | H.264 Baseline/Main, progressive |
| Resolution | ≤ 720p30 or 480p60 (raise after timing) |
| Audio | AAC-LC stereo or PCM s16le @ 48 kHz |
| Container | MP4/fMP4; ARM demux → elementary NAL + audio |
| Bitrate | Soft cap; PMS weak ladder on direct-play fail |

## Attack order

1. **ARM demux + elementary feed** into FPGA FIFO (clean boundaries; reuse Phase 2 resolve).
2. **Frame store in SDRAM** (triple buffer unique frames) + present engine already proven (Phase 1 cadence).
3. **H.264 decode soft-core / open IP** sized for Cyclone V:
   - Evaluate open cores (e.g. hardh264-class / simplified Baseline pipelines) for ALM/BRAM cost.
   - Fallback: hybrid ARM NEON decode of intra-only profiles is temporary only.
4. **Audio FIFO in present domain** (replace dual-process MrAudio pump for lip-sync ≤±40 ms).

## Memory map (Phase 3)

| Resource | Role |
|----------|------|
| BRAM | NAL/entropy FIFOs, linebufs, audio ring |
| SDRAM | Decoded unique frame store (console VRAM pattern) |
| DDR3 | Stream buffers, ARM↔FPGA bulk, large modes |
| FPGA | Decode + cadence present + AUDIO_L/R |
| ARM | GDM/companion/resolve/demux, not pixel loop |

## Intermediate milestone (before full H.264 IP)

**RGB frame store on FPGA** (still FFmpeg decode on ARM; present is FPGA vsync):

```text
Phase 3.0 (in tree now):
  F1 / ioctl raw RGB565 320×240 → frame_ingest → dual-bank BRAM frame_store
  present_core mux: Bars | Frame store (OSD O[9])
  cadence + tone unchanged

Phase 3.1 (done this fire):
  `fpga_spi` + `push_frame` — HPS SPI FIO_FILE_TX → frame_ingest
  PRESENT=fb0|fpga|both conf; dual present throttles SPI to every 4th frame
  HW: push_frame 153600B in ~99–127ms; continuous frame_tx during testsrc play
  Auto-present: frame_store shows as soon as has_frame (O[9]=Force bars for debug)

Phase 3.2 (done):
  `audio_fifo` + `audio_ingest` — F2 s16le stereo @48k → present-domain ring
  Prefers FIFO over OSD tone; underrun sticky; HW push index=2
  Continuous misterplexd: MrAudio + F2 SPI chunks (8 KiB = DEPTH 2048 samples)
  audio_ingest **append-mode** (no per-chunk flush); status[10] flush on play start
  M10K fit: ALMs ~19%, block memory ~51%, RAM blocks ~67% (DEPTH 2048)
  HW: multi-chunk F2 OK (~17 ms/16 KiB); live play f2==audio bytes
  `tests/hw/test_f2_append.sh`

Phase 3.3 scaffold (HW-green):
  F3 ioctl → stream_ingest (append) → bitstream_fifo 32 KiB M10K → nalu_scanner
  Scanner counts annex-B start codes (00 00 01 / 00 00 00 01); LED on has_stream
  ARM: `sendBitstreamChunk` / push_frame --index 3; `scripts/gen_test_annexb.py`
  HW: `tests/hw/test_f3_bitstream.sh`; unit `test_annexb_count`
  Fit: block mem ~56%, RAM blocks ~73% (bitstream 262144 bits / 32 M10K)
  Core status readback (UIO_GET_STATUS 0x29 / status_in):
    [0] has_frame [1] has_audio [2] has_stream [3] underrun
    [15:8] last_nal_type  [31:16] nalu_count  [47:32] fifo_level
    [63:48] wr_count_lo  [95:64] bytes_seen  [127:96] bytes_in
  `push_frame --status` dumps fields; HW test asserts nalu≥4 after F3 push

Phase 3.3b (next):
  H.264 Baseline soft-core / open IP → YUV → frame_store
  Optional parallel: DDRAM frame path (SPI RGB565 ~100–160 ms/frame bottleneck)
```

### 3.0 HW bring-up

1. Build RBF: `make build-rbf` (Quartus via misterfpga-dev).
2. Deploy: `./scripts/deploy_plex_core.sh`.
3. `python3 scripts/gen_test_frame.py /tmp/plex_test_320x240.rgb565` and copy to SD.
4. OSD: load frame via **F1**, set **Video source = Frame store**.
5. Expect yellow border + color bars + orange diagonal (not internal pattern block).

## H.264 soft-core evaluation notes

| Option | Pros | Cons for Cyclone V 5CSEBA6 |
|--------|------|----------------------------|
| Open hardh264-class / VexRiscv+accel | Real Baseline | ALM/BRAM cost; integration effort |
| Simplified Baseline intra-only | Fits fabric | Limited library titles |
| ARM demux + FPGA IDCT/MC only | Incremental | Still ARM-heavy |
| PMS ladder → Profile-1 elementary | Product path | Needs soft-core ready |

**Bring-up order:** F3 byte path (done scaffold) → NAL parse stats → Baseline decode IP → YUV→RGB565 → frame_store swap.

## Acceptance

- Same titles as Phase 2 cast path
- ARM CPU mostly idle during play (protocol + demux)
- A/V sync ≤ ±40 ms; audioUnderrun ≈ 0; no stuck frame
- Kill daemon / stop never hangs core

## Non-goals (Phase 3)

- Arbitrary 4K HEVC remux without PMS ladder
- Optical-flow interpolation
- Replacing PMS
