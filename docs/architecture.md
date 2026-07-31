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

## Phase 1

Self-contained proof without ARM feed:

- `present_cadence` — unique advance math (unit-tested in C++)
- `colorbars` — timing + patterns driven by **content_index**
- `audio_tone` — continuous samples on `CLK_AUDIO`
- OSD selects content FPS and pattern

This validates **vsync-owned present** and **film cadence** before Plex protocol lands.

## Phase 2 (current transitional path)

```text
Plex Web / curl playMedia
        │
        ▼
misterplexd companion (:3005) + GDM
        │ resolve (local path | PMS universal weak)
        ├──────────────────────────────┐
        ▼                              ▼
FFmpeg video → RGB24 320×240    FFmpeg audio → s16le 48k stereo
        │                              │
        ▼                              ▼
/dev/fb0 → MiSTer_fb/ascal     /dev/MrAudio → SPI DMA ring → sys audio mix
        │                              │
        └────────── HDMI/VGA + analog out ──────────┘
```

- Pause/stop/seek signal **both** video and audio process groups (SIGSTOP/TERM).
- Companion listen sockets use `FD_CLOEXEC`; media children close FDs ≥3 (orphaned ffmpeg must not hold `:3005`).
- Timeline reports scrubber-friendly play-queue fields when media is bound.
- **Not yet native present:** ARM still owns decode; FPGA owns scanout + MrAudio consumer.
- Next (Phase 3): elementary H.264 into FPGA FIFO; present-domain audio FIFO for lip-sync without dual FFmpeg.
- **Select Player / cast target:** Plex Web polls **`companionServer`**
  `/clients` + `/neighborhood/devices` (not "the browsed library server").
  `CompanionServerManager` picks the first owned private PMS in **FriendlyName**
  A→Z order. Blank/duplicate names can make Web ask a PMS with empty `/clients`
  (e.g. Android/SHIELD) while another PMS already lists MiSTerPlex. Remedy:
  distinct FriendlyName on the cast-from PMS — not plex.tv registration, not
  removing other servers. See
  [v2-video-baseline.md](v2-video-baseline.md#cast-target-missing-in-select-player-companionserver--friendlyname-2026-07-30).

## Memory map (evolving)

| Stage | BRAM | SDRAM | DDR3 |
|-------|------|-------|------|
| Phase 1 | timing only | unused (tri-stated) | unused |
| Phase 2 | audio ring, linebuf | triple frame store from ARM RGB | stream buffers |
| Phase 3 | entropy FIFOs | decoded unique frames | bitstream + large modes |

## Display policy

1. **Match source Hz** when CRT/LCD accepts modeline (24/30/50/60) — **TODO** HPS switchres; see [match-source-hz.md](match-source-hz.md).
2. Else **fixed display Hz** + **cadence in present** (shipped: OSD Content FPS + `present_cadence`; never force 60 unique RGB/s through decode).
3. Audio continuous; lip-sync delay in present-domain FIFO (Phase 2+).

## Codec policy

- **Profile MiSTerPlex-1:** constrained H.264 (+ stereo AAC/PCM) the core guarantees.
- **Compatibility:** PMS ladder produces that profile; MiSTer still presents natively.
- Dual-A9 FFmpeg is **bootstrap only**, not the quality ceiling.
