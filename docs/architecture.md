# MiSTerPlex architecture

## Design principle

**Console cores prove the board can play high-res video without ARM in the pixel path.**  
MiSTerPlex follows that model: the FPGA owns present (and eventually decode); ARM owns Plex and networking.

## Data path (target)

```text
Plex clients ──► ARM (GDM/companion/resolve/demux)
                      │ elementary / compressed payload
                      ▼
                 FPGA ingest FIFO (BRAM)
                      │
                 decode pipeline (Phase 3+)
                      │ unique frames
                 SDRAM / DDR frame store
                      │
                 present engine @ modeline VBL
                   · cadence 3:2 / 2:2 when content < display Hz
                   · hold last unique when not advancing
                      │
                 VGA/HDMI (sys) + AUDIO_L/R
```

## Phase 1 (current)

Self-contained proof without ARM feed:

- `present_cadence` — unique advance math (unit-tested in C++)
- `colorbars` — timing + patterns driven by **content_index**
- `audio_tone` — continuous samples on `CLK_AUDIO`
- OSD selects content FPS and pattern

This validates **vsync-owned present** and **film cadence** before Plex protocol lands.

## Memory map (evolving)

| Stage | BRAM | SDRAM | DDR3 |
|-------|------|-------|------|
| Phase 1 | timing only | unused (tri-stated) | unused |
| Phase 2 | audio ring, linebuf | triple frame store from ARM RGB | stream buffers |
| Phase 3 | entropy FIFOs | decoded unique frames | bitstream + large modes |

## Display policy

1. **Match source Hz** when CRT/LCD accepts modeline (24/30/50/60).
2. Else **fixed display Hz** + **cadence in present** (never force 60 unique RGB/s through decode).
3. Audio continuous; lip-sync delay in present-domain FIFO (Phase 2+).

## Codec policy

- **Profile MiSTerPlex-1:** constrained H.264 (+ stereo AAC/PCM) the core guarantees.
- **Compatibility:** PMS ladder produces that profile; MiSTer still presents natively.
- Dual-A9 FFmpeg is **bootstrap only**, not the quality ceiling.
