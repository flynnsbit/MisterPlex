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

Phase 3.1 (next):
  misterplexd → continuous frame stream (ioctl/EXT_BUS/DDRAM window)
  FFmpeg RGB → pack RGB565 → HPS write → swap on VBL

Phase 3.2:
  PCM → core audio FIFO (retire dual-process MrAudio pump for lip-sync)

Phase 3.3:
  H.264 soft-core / elementary NAL feed
```

### 3.0 HW bring-up

1. Build RBF: `make build-rbf` (Quartus via misterfpga-dev).
2. Deploy: `./scripts/deploy_plex_core.sh`.
3. `python3 scripts/gen_test_frame.py /tmp/plex_test_320x240.rgb565` and copy to SD.
4. OSD: load frame via **F1**, set **Video source = Frame store**.
5. Expect yellow border + color bars + orange diagonal (not internal pattern block).

## Acceptance

- Same titles as Phase 2 cast path
- ARM CPU mostly idle during play (protocol + demux)
- A/V sync ≤ ±40 ms; audioUnderrun ≈ 0; no stuck frame
- Kill daemon / stop never hangs core

## Non-goals (Phase 3)

- Arbitrary 4K HEVC remux without PMS ladder
- Optical-flow interpolation
- Replacing PMS
